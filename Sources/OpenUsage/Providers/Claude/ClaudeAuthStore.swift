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

    /// Whether this candidate carries a non-blank access token — the single definition of "usable"
    /// shared by `refresh()`'s candidate filter and `hasLocalCredentials()`'s first-run detection, so
    /// the two can never drift.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

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
    case desktopAppOnly
    case credentialStoreUnreadable
    case invalidCredentialData
    case sessionExpired
    case tokenExpired
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .desktopAppOnly:
            return "Signed in to the Claude desktop app? OpenUsage needs a CLI login — run `claude` in a terminal and sign in once."
        case .credentialStoreUnreadable:
            return "Couldn't read Claude credentials. Check access to the Claude credential file and Keychain, then try again."
        case .invalidCredentialData:
            return "Claude credentials are invalid. Run `claude` to sign in again."
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
        case .notLoggedIn, .desktopAppOnly, .credentialStoreUnreadable,
             .invalidCredentialData, .invalidOAuthURL:
            return false
        }
    }
}

struct ClaudeOAuthConfig: Hashable, Sendable {
    var usageURL: URL
    var refreshURL: URL
    var clientID: String
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

    /// All usable credential sources currently on disk/keychain, in fixed keychain-before-file order,
    /// for the refresh loop to try in order. A missing source contributes nothing; an unreadable or
    /// malformed source throws only when no usable sibling source exists. The provider probes each and —
    /// on an auth-expiry error
    /// (`ClaudeAuthError.allowsAuthFallback`) — falls through to the next, so an external `claude`
    /// re-login is picked up no matter which source it lands in, even when a stale/locked-out token still
    /// sits in another. Re-read on every refresh; nothing is cached in memory.
    func loadCredentialCandidates() throws -> [ClaudeCredentialState] {
        let storedLoad = orderedStoredCandidates()
        let stored = storedLoad.candidates
        guard let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") else {
            if stored.isEmpty, let error = storedLoad.firstError { throw error }
            return stored
        }
        // An explicit `CLAUDE_CODE_OAUTH_TOKEN` is inference-only (typically a `claude setup-token`
        // token): it can run the model but 403s on the usage endpoint. It also reaches us when the user
        // only *ambiently* has it exported — OpenUsage captures the login-shell environment — so it must
        // not shadow a real interactive login that CAN read usage. Prefer any stored login able to fetch
        // live usage (keychain-first, then file) for the usage call, with the env token kept as a
        // trailing inference-only fallback for the refresh loop. With no live-capable stored login (a
        // genuinely headless setup) the env token is the only candidate — unchanged: spend tiles still
        // load. Nothing is silenced; only the credential SELECTED for the usage fetch changes.
        let liveCapable = stored.filter { liveUsageAvailability($0) == .available }
        // Borrow plan metadata (subscription type / scopes) for display from the credential actually
        // preferred — the live-capable login when there is one, else the first stored login — so the
        // fallback doesn't inherit metadata from a login we decided not to use. Source it honestly as
        // `.environment`: the token came from the env, so the refresh-start diagnostics name the real
        // source when the loop falls back to it, and `save()` correctly no-ops instead of writing an env
        // token back into the keychain under a borrowed source.
        let base = liveCapable.first ?? stored.first
        var oauth = base?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        let envCandidate = ClaudeCredentialState(
            oauth: oauth,
            source: .environment,
            fullData: base?.fullData,
            inferenceOnly: true
        )
        return liveCapable.isEmpty ? [envCandidate] : liveCapable + [envCandidate]
    }

    /// Data folders the Claude desktop app keeps under `~/Library/Application Support` — the standalone
    /// Claude Code app and the Claude Code area inside the main Claude app. Their presence (checked only
    /// when no CLI credentials exist anywhere) means the user likely signed in through the desktop app,
    /// whose session lives in an Electron `safeStorage`-encrypted blob OpenUsage can't read (#825).
    private static let desktopAppDataPaths = [
        "~/Library/Application Support/Claude Code",
        "~/Library/Application Support/Claude/claude-code"
    ]

    /// Whether a desktop-app login is the likely reason no CLI credentials were found, so the provider
    /// can explain that a one-time `claude` CLI login is needed instead of a bare "Not logged in".
    func hasDesktopAppData() -> Bool {
        Self.desktopAppDataPaths.contains { files.exists($0) }
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

    /// Why the live-usage endpoint (`/api/oauth/usage`, which backs Session / Weekly / Sonnet / Extra
    /// Usage) can or can't be called for a credential. Reading usage requires the `user:profile` scope,
    /// so a token that only carries `user:inference` (e.g. one minted by `claude setup-token`) can't —
    /// and the provider surfaces that as a friendly "re-login" notice instead of silently blank bars.
    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// An explicit `CLAUDE_CODE_OAUTH_TOKEN`: inference-only by design, so there's nothing to fetch
        /// and nothing to nag about — the spend tiles still load from local logs.
        case inferenceOnlyToken
        /// A stored login whose granted scopes lack `user:profile`. The usage endpoint would reject it,
        /// so the session/weekly bars can't load until the user signs in again with `claude`.
        case missingProfileScope
    }

    /// The required scope for the usage endpoint. A credential missing it can authenticate for inference
    /// but can't read subscription usage windows.
    static let usageScope = "user:profile"

    func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inferenceOnly { return .inferenceOnlyToken }
        // Older credentials predate the scopes field; treat an absent/empty list as "unknown, allow" so
        // we don't suppress usage for tokens that actually carry the access (and would 403 loudly if not).
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
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
            clientID: endpoints.clientID
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
    /// later expiry (the #738 regression from ranking purely by expiry). Distinct current-user, legacy,
    /// hashed-service, and base-service Keychain entries remain separate fallback candidates; duplicate
    /// token pairs returned by overlapping Keychain lookups are attempted only once. The source kind
    /// (never the token) is logged so a "locked out" report can be diagnosed from which source was chosen.
    private struct CandidateLoad {
        var candidates: [ClaudeCredentialState] = []
        var firstError: ClaudeAuthError?

        mutating func append(_ candidate: ClaudeCredentialState) {
            let alreadyLoaded = candidates.contains {
                $0.oauth.accessToken == candidate.oauth.accessToken &&
                $0.oauth.refreshToken == candidate.oauth.refreshToken
            }
            if !alreadyLoaded { candidates.append(candidate) }
        }

        mutating func record(_ error: ClaudeAuthError) {
            if firstError == nil { firstError = error }
        }
    }

    private func orderedStoredCandidates() -> CandidateLoad {
        var load = loadKeychainCredentials()
        let fileLoad = loadFileCredentials()
        for candidate in fileLoad.candidates {
            load.append(candidate)
        }
        if let error = fileLoad.firstError { load.record(error) }

        if load.candidates.count > 1 {
            let labels = load.candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = load.candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return load
    }

    private func loadFileCredentials() -> CandidateLoad {
        let path = credentialsPath()
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(path) else { return CandidateLoad() }
            text = stored
        } catch {
            AppLog.error(LogTag.auth("claude"), "credential file read failed")
            return CandidateLoad(firstError: .credentialStoreUnreadable)
        }

        guard let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            AppLog.error(LogTag.auth("claude"), "credential file is malformed or has no usable access token")
            return CandidateLoad(firstError: .invalidCredentialData)
        }
        return CandidateLoad(candidates: [
            ClaudeCredentialState(
                oauth: oauth,
                source: .file,
                fullData: parsed,
                inferenceOnly: false
            )
        ])
    }

    private func loadKeychainCredentials() -> CandidateLoad {
        var load = CandidateLoad()
        for service in keychainServiceCandidates() {
            do {
                if let value = try keychain.readGenericPasswordForCurrentUser(service: service) {
                    if let state = credentialState(
                        from: value,
                        service: service,
                        source: .keychainCurrentUser(service: service)
                    ) {
                        load.append(state)
                    } else {
                        AppLog.error(LogTag.auth("claude"), "current-user Keychain credential is malformed or has no usable access token")
                        load.record(.invalidCredentialData)
                    }
                }
            } catch {
                AppLog.error(LogTag.auth("claude"), "current-user Keychain credential read failed")
                load.record(.credentialStoreUnreadable)
            }

            do {
                if let value = try keychain.readGenericPassword(service: service) {
                    if let state = credentialState(
                        from: value,
                        service: service,
                        source: .keychainLegacy(service: service)
                    ) {
                        load.append(state)
                    } else {
                        AppLog.error(LogTag.auth("claude"), "legacy Keychain credential is malformed or has no usable access token")
                        load.record(.invalidCredentialData)
                    }
                }
            } catch {
                AppLog.error(LogTag.auth("claude"), "legacy Keychain credential read failed")
                load.record(.credentialStoreUnreadable)
            }
        }
        return load
    }

    /// Parse one present keychain value into a credential state. A `nil` result means the stored value
    /// is malformed or tokenless; absence is represented by the keychain accessor returning `nil` before
    /// this helper is called.
    private func credentialState(
        from value: String,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
