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
    }

    var oauth: ClaudeOAuth
    var source: Source
    var fullData: ClaudeCredentialsFile?
    var inferenceOnly: Bool
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .sessionExpired:
            return "Session expired. Run `claude` to log in again."
        case .tokenExpired:
            return "Token expired. Run `claude` to log in again."
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
        case .notLoggedIn:
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

    /// All credential sources currently on disk/keychain, freshest first, for the refresh loop to try in
    /// order. The provider probes each and — on an auth-expiry error (`ClaudeAuthError.allowsAuthFallback`)
    /// — falls through to the next, so an external `claude` re-login is picked up no matter which source
    /// it lands in, even when a stale/locked-out token still sits in another. Re-read on every refresh;
    /// nothing is cached in memory.
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

    /// The first (freshest) credential candidate. Kept for callers that only need a single source.
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
        AppLog.debug(LogTag.auth("claude"), "persisted rotated credentials (source=\(sourceLabel(state.source)))")
    }

    private func sourceLabel(_ source: ClaudeCredentialState.Source) -> String {
        switch source {
        case .file: "file"
        case .keychainCurrentUser: "keychainCurrentUser"
        case .keychainLegacy: "keychainLegacy"
        case .environment: "environment"
        }
    }

    func canFetchLiveUsage(_ state: ClaudeCredentialState) -> Bool {
        guard !state.inferenceOnly else { return false }
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return true }
        return scopes.contains("user:profile")
    }

    func claudeHomeOverride() -> String? {
        envText("CLAUDE_CONFIG_DIR")
    }

    func oauthConfig() -> ClaudeOAuthConfig {
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

        return ClaudeOAuthConfig(
            usageURL: URL(string: "\(baseAPI)/api/oauth/usage")!,
            refreshURL: URL(string: refreshURL)!,
            clientID: clientID,
            oauthFileSuffix: suffix
        )
    }

    func keychainServiceCandidates() -> [String] {
        let base = "\(Self.keychainServicePrefix)\(oauthConfig().oauthFileSuffix)-credentials"
        if let configDir = claudeHomeOverride() {
            return ["\(base)-\(hashSuffix(configDir))", base]
        }
        return [base]
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// Keychain and file credentials, ordered freshest-first by access-token expiry. A later expiry means
    /// a more recent login, so a fresh external re-login is preferred over a stale token still sitting in
    /// another source. The sort is stable, so when expiries tie — or are both absent — keychain stays
    /// ahead of file, preserving the historical precedence. The source kind (never the token) is logged
    /// so a "locked out" report can be diagnosed from which source was chosen.
    private func orderedStoredCandidates() -> [ClaudeCredentialState] {
        var candidates: [ClaudeCredentialState] = []
        if let keychain = loadKeychainCredentials() { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let lhsExpiry = lhs.element.oauth.expiresAt ?? -.greatestFiniteMagnitude
            let rhsExpiry = rhs.element.oauth.expiresAt ?? -.greatestFiniteMagnitude
            if lhsExpiry == rhsExpiry { return lhs.offset < rhs.offset }
            return lhsExpiry > rhsExpiry
        }.map(\.element)

        if ordered.count > 1 {
            let labels = ordered.map { sourceLabel($0.source) }.joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (freshest first): \(labels)")
        } else if let only = ordered.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(sourceLabel(only.source))")
        }
        return ordered
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
            if let value = try? keychain.readGenericPasswordForCurrentUser(service: service),
               let parsed = Self.parseCredentials(value),
               let oauth = parsed.claudeAiOauth,
               oauth.accessToken?.isEmpty == false {
                AppLog.debug(.keychain, "read hit service=\(service)")
                return ClaudeCredentialState(
                    oauth: oauth,
                    source: .keychainCurrentUser(service: service),
                    fullData: parsed,
                    inferenceOnly: false
                )
            }

            if let value = try? keychain.readGenericPassword(service: service),
               let parsed = Self.parseCredentials(value),
               let oauth = parsed.claudeAiOauth,
               oauth.accessToken?.isEmpty == false {
                AppLog.debug(.keychain, "read hit service=\(service)")
                return ClaudeCredentialState(
                    oauth: oauth,
                    source: .keychainLegacy(service: service),
                    fullData: parsed,
                    inferenceOnly: false
                )
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return nil
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
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}


