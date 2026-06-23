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

    func loadCredentials() -> ClaudeCredentialState? {
        let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN")
        let stored = loadStoredCredentials()
        guard let envAccessToken else {
            return stored
        }

        var oauth = stored?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        return ClaudeCredentialState(
            oauth: oauth,
            source: stored?.source ?? .environment,
            fullData: stored?.fullData,
            inferenceOnly: true
        )
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

    private func loadStoredCredentials() -> ClaudeCredentialState? {
        if let keychain = loadKeychainCredentials() { return keychain }
        if let file = loadFileCredentials() { return file }
        return nil
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


