import Foundation

/// The Kimi Code CLI's OAuth credential file, as the CLI writes it (`access_token` / `refresh_token` /
/// `expires_at` epoch seconds, fractional in older files). Every field is optional so a partial file
/// still decodes; `KimiOAuthState.isUsable` decides whether it can serve the usage API.
struct KimiOAuthCredentials: Codable, Hashable, Sendable {
    var accessToken: String? = nil
    var refreshToken: String? = nil
    var expiresAt: Double? = nil
    var expiresIn: Double? = nil
    var scope: String? = nil
    var tokenType: String? = nil

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

/// A loaded OAuth credential plus the file it came from, so rotated tokens persist back to the same
/// path the CLI reads.
struct KimiOAuthState: Hashable, Sendable {
    var credentials: KimiOAuthCredentials
    var path: String

    /// Whether this credential can serve the usage API at all — an access token to send, or a refresh
    /// token to mint one with. `hasLocalCredentials()` checks the same bar, so the two can never drift.
    var isUsable: Bool {
        credentials.accessToken?.isEmpty == false || credentials.refreshToken?.isEmpty == false
    }
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case invalidKey
    case missingKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in with the Kimi Code CLI or add an API key."
        case .sessionExpired:
            return "Session expired. Sign in with the Kimi Code CLI again."
        case .invalidKey:
            return "Kimi API key invalid. Check your key in the Kimi Code console."
        case .missingKey:
            return "No Kimi API key. Set KIMI_API_KEY or add it to ~/.config/openusage/kimi.json."
        case .saveFailed:
            return "Couldn't save the Kimi API key."
        case .deleteFailed:
            return "Couldn't remove the saved Kimi API key."
        }
    }
}

/// Reads the two credential sources Kimi Code offers: the OAuth token file the Kimi Code CLI already
/// maintains, and a user-supplied API key (config file or environment) for setups without the CLI —
/// e.g. a Kimi Code subscription driven through Claude Code with a console API key.
struct KimiAuthStore: Sendable {
    /// CLI credential files, current layout first: today's Kimi Code CLI keeps its tokens under
    /// `~/.kimi-code/`; early releases used `~/.kimi/`.
    static let oauthPaths = [
        "~/.kimi-code/credentials/kimi-code.json",
        "~/.kimi/credentials/kimi-code.json"
    ]
    static let configPaths = ["~/.config/openusage/kimi.json"]
    static let environmentNames = ["KIMI_API_KEY"]
    /// Refresh once the access token is within this window of `expires_at` — the CLI's own 5-minute
    /// slack. Kimi access tokens live ~15 minutes, so proactive refresh is the norm, not the exception.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60

    var files: TextFileAccessing
    var now: @Sendable () -> Date
    private let keyStore: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.now = now
        keyStore = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { KimiAuthError($0) }
        )
    }

    // MARK: - API key

    func loadAPIKey() -> String? { keyStore.loadKey() }
    func keyStatus() -> APIKeyStatus { keyStore.keyStatus() }
    func saveAPIKey(_ key: String) throws { try keyStore.saveKey(key) }
    func deleteAPIKey() throws { try keyStore.deleteKey() }

    // MARK: - CLI OAuth tokens

    /// The first usable CLI credential across the known paths, or `nil` when the user never signed in.
    func loadOAuthState() -> KimiOAuthState? {
        for path in Self.oauthPaths {
            if let state = loadOAuth(at: path) {
                return state
            }
        }
        return nil
    }

    /// Reads the credential from a single on-disk file — used when re-reading the exact source we
    /// already loaded from (the CLI may have rotated the token since), so we don't re-scan every path.
    func loadOAuth(at path: String) -> KimiOAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let credentials = ProviderParse.decodeJSONWithHexFallback(text, as: KimiOAuthCredentials.self)
        else {
            return nil
        }
        let state = KimiOAuthState(credentials: credentials, path: path)
        return state.isUsable ? state : nil
    }

    /// Persist rotated tokens back to the file they came from, in the CLI's own field names, so the
    /// CLI picks up the new refresh token on its next run.
    func save(_ state: KimiOAuthState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state.credentials)
        guard let text = String(data: data, encoding: .utf8) else {
            throw KimiAuthError.saveFailed
        }
        try files.writeText(state.path, text)
    }

    /// Whether the access token should be proactively refreshed: missing, no expiry on record, or at /
    /// within `accessTokenRefreshWindow` of `expires_at`.
    func needsRefresh(_ credentials: KimiOAuthCredentials) -> Bool {
        guard credentials.accessToken?.isEmpty == false else { return true }
        guard let expiresAt = credentials.expiresAt else { return true }
        return Date(timeIntervalSince1970: expiresAt).timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
    }
}
