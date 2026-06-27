import CryptoKit
import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Hashable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case environment

        /// Log-safe source kind — NEVER the keychain service name or any token.
        var label: String {
            switch self {
            case .file: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var fullData: ClaudeCredentialsFile?
    var inferenceOnly: Bool

    /// A token-free, log-safe one-line descriptor for diagnosing auth failures from a default-level
    /// (info) log: the source kind plus booleans for whether this candidate carries a refresh token and
    /// whether its access token is already expired (`expiresAt`, epoch ms, vs `now`). NEVER includes any
    /// token value or the credential blob — only the source kind and the two booleans. Why these two
    /// booleans: a candidate with `refresh=no` can never self-heal an expiry (the #738 root cause), and
    /// `expired=yes` explains why a refresh was needed at all.
    func diagnosticsLabel(now: Date) -> String {
        let refresh = (oauth.refreshToken?.isEmpty == false) ? "yes" : "no"
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) refresh=\(refresh) expired=\(expired)"
    }
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .sessionExpired:
            return "Session expired. Run `claude` to log in again."
        case .tokenExpired:
            return "Token expired. Run `claude` to log in again."
        case .invalidOAuthURL(let value):
            return "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        }
    }

    /// Whether a failure on one credential source should fall through to the next one rather than
    /// failing the whole refresh. An expired/revoked token in the preferred source (a stale keychain
    /// entry from a prior login that later "locked out") must not shadow a fresh token an external
    /// `claude` re-login wrote to a different source — so the token-is-bad cases allow a fallback,
    /// while "no credentials at all" does not (there is nothing better to try). Mirrors
    /// `CodexAuthError.allowsAuthFallback`.
    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenExpired:
            return true
        case .notLoggedIn, .invalidOAuthURL:
            return false
        }
    }
}

struct ClaudeOAuthConfig: Hashable, Sendable {
    var usageURL: URL
    var refreshURL: URL
    var clientID: String
    var oauthFileSuffix: String
}

struct ClaudeAuthStore: Sendable {
    private static let defaultClaudeHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let prodBaseAPIURL = "https://api.anthropic.com"
    private static let prodRefreshURL = "https://platform.claude.com/v1/oauth/token"
    private static let prodClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let nonProdClientID = "22422756-60c9-4084-8eb7-27705fd5cf9a"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
    }

    /// All credential sources currently on disk/keychain, in fixed keychain-before-file order, for the
    /// refresh loop to try in order. The provider probes each and — on an auth-expiry error
    /// (`ClaudeAuthError.allowsAuthFallback`) — falls through to the next, so an external `claude`
    /// re-login is picked up no matter which source it lands in, even when a stale/locked-out token still
    /// sits in another. Re-read on every refresh; nothing is cached in memory.
    func loadCredentialCandidates() -> [ClaudeCredentialState] {
        // An explicit env token overrides everything and is inference-only (no live usage call), so there
        // is no auth failure to fall back from — return the single env-wrapped candidate.
        if let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") {
            let stored = orderedStoredCandidates().first
            var oauth = stored?.oauth ?? ClaudeOAuth()
            oauth.accessToken = envAccessToken
            return [ClaudeCredentialState(
                oauth: oauth,
                source: stored?.source ?? .environment,
                fullData: stored?.fullData,
                inferenceOnly: true
            )]
        }
        return orderedStoredCandidates()
    }

    /// The first (preferred) credential candidate — the keychain when present, else the file. Kept for
    /// callers that only need a single source.
    func loadCredentials() -> ClaudeCredentialState? {
        loadCredentialCandidates().first
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    func save(_ state: ClaudeCredentialState) throws {
        var fullData = state.fullData ?? ClaudeCredentialsFile()
        fullData.claudeAiOauth = state.oauth
        let data = try JSONEncoder().encode(fullData)
        guard let text = String(data: data, encoding: .utf8) else { return }

        switch state.source {
        case .file:
            try files.writeText(credentialsPath(), text)
        case .keychainCurrentUser(let service):
            try keychain.writeGenericPasswordForCurrentUser(service: service, value: text)
        case .keychainLegacy(let service):
            try keychain.writeGenericPassword(service: service, value: text)
        case .environment:
            return
        }
        // NEVER log the credential blob/tokens — only that a rotation was persisted, and to where.
        AppLog.debug(LogTag.auth("claude"), "persisted rotated credentials (source=\(state.source.label))")
    }

    func canFetchLiveUsage(_ state: ClaudeCredentialState) -> Bool {
        guard !state.inferenceOnly else { return false }
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return true }
        return scopes.contains("user:profile")
    }

    func claudeHomeOverride() -> String? {
        envText("CLAUDE_CONFIG_DIR")
    }

    // Resolved OAuth endpoint strings before URL validation. The suffix is derived from the same
    // env-var branching as the URLs but never depends on URL validity, so the (non-throwing) keychain
    // candidate path can read it without risking a throw.
    private struct ResolvedOAuthEndpoints {
        var baseAPI: String
        var refreshURL: String
        var clientID: String
        var suffix: String
    }

    private func resolveOAuthEndpoints() -> ResolvedOAuthEndpoints {
        var baseAPI = Self.prodBaseAPIURL
        var refreshURL = Self.prodRefreshURL
        var clientID = Self.prodClientID
        var suffix = ""

        let isAntUser = envText("USER_TYPE") == "ant"
        if isAntUser, envFlag("USE_LOCAL_OAUTH") {
            let base = (envText("CLAUDE_LOCAL_OAUTH_API_BASE") ?? "http://localhost:8000").trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-local-oauth"
        } else if isAntUser, envFlag("USE_STAGING_OAUTH") {
            baseAPI = "https://api-staging.anthropic.com"
            refreshURL = "https://platform.staging.ant.dev/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-staging-oauth"
        }

        if let custom = envText("CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            let base = custom.trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            suffix = "-custom-oauth"
        }
        if let override = envText("CLAUDE_CODE_OAUTH_CLIENT_ID") {
            clientID = override
        }

        return ResolvedOAuthEndpoints(baseAPI: baseAPI, refreshURL: refreshURL, clientID: clientID, suffix: suffix)
    }

    // baseAPI/refreshURL can derive from user-set env vars (CLAUDE_CODE_CUSTOM_OAUTH_URL,
    // CLAUDE_LOCAL_OAUTH_API_BASE). A malformed value is a system-boundary input that must fail
    // loudly — never force-unwrap (crashes the app) and never silently fall back to prod (that hides
    // the misconfiguration and would send the user's token to production).
    func oauthConfig() throws -> ClaudeOAuthConfig {
        let endpoints = resolveOAuthEndpoints()
        let usageURLString = "\(endpoints.baseAPI)/api/oauth/usage"
        guard let usageURL = URL(string: usageURLString) else {
            throw ClaudeAuthError.invalidOAuthURL(usageURLString)
        }
        guard let refreshURL = URL(string: endpoints.refreshURL) else {
            throw ClaudeAuthError.invalidOAuthURL(endpoints.refreshURL)
        }
        return ClaudeOAuthConfig(
            usageURL: usageURL,
            refreshURL: refreshURL,
            clientID: endpoints.clientID,
            oauthFileSuffix: endpoints.suffix
        )
    }

    func keychainServiceCandidates() -> [String] {
        // Only needs the file suffix, which never fails — keep this off the throwing URL path so
        // credential loading stays forgiving even when a custom OAuth URL is malformed.
        let base = "\(Self.keychainServicePrefix)\(resolveOAuthEndpoints().suffix)-credentials"
        if let configDir = claudeHomeOverride() {
            return ["\(base)-\(hashSuffix(configDir))", base]
        }
        return [base]
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// Keychain and file credentials in fixed keychain-before-file order. The keychain is Claude Code's
    /// source of truth on macOS — recent versions keep the current session there and can leave a stale
    /// `~/.claude/.credentials.json` behind — so it must win when valid; the file is only a fallback
    /// (older installs / Linux-style layouts). The refresh loop still falls through to the file on an
    /// auth-expiry error, so a fresh external `claude` re-login that landed in the other source is picked
    /// up (#687) WITHOUT letting a stale file outrank the live keychain just because its token carries a
    /// later expiry (the #738 regression from ranking purely by expiry). The source kind (never the
    /// token) is logged so a "locked out" report can be diagnosed from which source was chosen.
    private func orderedStoredCandidates() -> [ClaudeCredentialState] {
        var candidates: [ClaudeCredentialState] = []
        if let keychain = loadKeychainCredentials() { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        if candidates.count > 1 {
            let labels = candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return candidates
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let text = try? files.readText(path),
              let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(oauth: oauth, source: .file, fullData: parsed, inferenceOnly: false)
    }

    private func loadKeychainCredentials() -> ClaudeCredentialState? {
        // The service name is safe to log; NEVER log the returned credential blob / OAuth tokens.
        for service in keychainServiceCandidates() {
            if let state = credentialState(
                from: try? keychain.readGenericPasswordForCurrentUser(service: service),
                service: service, source: .keychainCurrentUser(service: service)
            ) {
                return state
            }
            if let state = credentialState(
                from: try? keychain.readGenericPassword(service: service),
                service: service, source: .keychainLegacy(service: service)
            ) {
                return state
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return nil
    }

    /// Parse one keychain hit into a credential state, or `nil` if it's absent / malformed / tokenless.
    /// Shared by the current-user and legacy reads so they don't repeat the parse-guard-log-build block;
    /// the keychain read itself stays at the call site to preserve the read order and error-swallowing.
    private func credentialState(
        from value: String?,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        AppLog.debug(.keychain, "read hit service=\(service)")
        return ClaudeCredentialState(oauth: oauth, source: source, fullData: parsed, inferenceOnly: false)
    }

    private func credentialsPath() -> String {
        "\(envText("CLAUDE_CONFIG_DIR") ?? Self.defaultClaudeHome)/\(Self.credentialFileName)"
    }

    private func envText(_ name: String) -> String? {
        guard let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func envFlag(_ name: String) -> Bool {
        guard let value = envText(name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}


