import CryptoKit
import Foundation

struct CodexTokens: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

struct CodexAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(path: String)
        case keychain
    }

    var auth: CodexAuth
    var source: Source

    /// Whether this candidate carries a non-empty OAuth access token — the same bar `refresh()`'s
    /// probe requires before fetching usage (an API-key-only auth.json can't serve the usage API).
    /// `hasLocalCredentials()`'s first-run detection checks this, so the two can never drift.
    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.isEmpty == false
    }
}

enum CodexAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenConflict
    case tokenRevoked
    case tokenExpired
    case usageAPIKey
    case invalidAuthPayload

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `codex` to authenticate."
        case .sessionExpired:
            return "Session expired. Run `codex` to log in again."
        case .tokenConflict:
            return "Token conflict. Run `codex` to log in again."
        case .tokenRevoked:
            return "Token revoked. Run `codex` to log in again."
        case .tokenExpired:
            return "Token expired. Run `codex` to log in again."
        case .usageAPIKey:
            return "Usage not available for API key."
        case .invalidAuthPayload:
            return "Codex auth data is invalid."
        }
    }

    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired:
            return true
        case .notLoggedIn, .usageAPIKey, .invalidAuthPayload:
            return false
        }
    }
}

/// Pins a `CodexAuthStore` to ONE extra account's credential sources: the `auth.json` in a specific
/// Codex home dir and/or a specific keychain item. The default instance leaves this `nil` and behaves
/// exactly as before (env `CODEX_HOME`, the default homes, the shared keychain item).
struct CodexAccountScope: Hashable, Sendable {
    var configDir: String?
    /// The keychain account attribute (`cli|<hash>`) — the `codex` CLI keeps every login under ONE
    /// service (`Codex Auth`) and distinguishes them by account, the mirror image of Claude Code's
    /// hash-suffixed services.
    var keychainAccount: String?
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// Refresh once the access token is within this window of its JWT `exp` — the same 5-minute slack
    /// the `codex` CLI itself uses, so OpenUsage rotates on the same schedule rather than guessing.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let authFile = "auth.json"
    private static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    /// When set, this store reads/writes ONLY the pinned account's sources (see `CodexAccountScope`).
    /// `nil` is the default instance — unchanged env-driven behavior.
    var account: CodexAccountScope?

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        account: CodexAccountScope? = nil
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
        self.account = account
    }

    func loadAuthCandidates() -> [CodexAuthState] {
        authPaths().compactMap { loadAuth(at: $0) }
    }

    /// Reads the credential from a single on-disk auth file — the targeted counterpart to
    /// `loadKeychainAuth()`, used when reloading the exact source we already loaded from so we don't
    /// re-scan every candidate path. Returns `nil` when the file is missing, unreadable, or doesn't
    /// carry token-like auth.
    func loadAuth(at path: String) -> CodexAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let auth = Self.parseAuth(text),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .file(path: path))
    }

    func loadKeychainAuth() -> CodexAuthState? {
        // A scoped store reads exactly its pinned keychain item (or nothing, for a file-only
        // account). The default instance prefers its own hash account — with several logins stored
        // under the shared "Codex Auth" service, a service-only lookup would return an arbitrary
        // one — and falls back to the service-only read for items predating the account attribute.
        let accounts: [String?]
        if let account {
            guard let keychainAccount = account.keychainAccount else { return nil }
            accounts = [keychainAccount]
        } else {
            accounts = [defaultKeychainAccount(), nil]
        }
        for keychainAccount in accounts {
            let value = try? keychainAccount.map { try keychain.readGenericPassword(service: Self.keychainService, account: $0) }
                ?? keychain.readGenericPassword(service: Self.keychainService)
            guard let value, let auth = Self.parseAuth(value), Self.hasTokenLikeAuth(auth) else { continue }
            return CodexAuthState(auth: auth, source: .keychain)
        }
        return nil
    }

    /// The keychain account attribute the `codex` CLI derives for a Codex home dir: `cli|` + the
    /// first 16 hex chars of SHA-256 over the canonicalized (symlink-resolved) path. The single home
    /// of this derivation — multi-account discovery reuses it to pair a dir with its keychain item.
    static func keychainAccountName(forConfigDir dir: String) -> String {
        let canonical = URL(fileURLWithPath: expandHome(dir)).standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|\(hex.prefix(16))"
    }

    /// The default account's keychain account attribute, derived from the same home resolution as
    /// `authPaths()` (env `CODEX_HOME`, else `~/.codex` — the CLI's own default).
    func defaultKeychainAccount() -> String {
        Self.keychainAccountName(forConfigDir: codexHome() ?? "~/.codex")
    }

    func save(_ state: CodexAuthState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = state.source.isFile ? [.prettyPrinted, .sortedKeys] : []
        let data = try encoder.encode(state.auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }

        switch state.source {
        case .file(let path):
            try files.writeText(path, text)
        case .keychain:
            // Target the same account attribute the credential was loaded under, so a rotation with
            // several logins stored under the shared service updates the right item.
            try keychain.writeGenericPassword(
                service: Self.keychainService,
                account: account?.keychainAccount ?? defaultKeychainAccount(),
                value: text
            )
        }
    }

    /// Whether the access token should be proactively refreshed.
    ///
    /// Prefers the access token's own JWT `exp` — refresh only when it is at (or within
    /// `accessTokenRefreshWindow` of) expiry, mirroring the `codex` CLI. The hardcoded 8-day
    /// wall-clock age is only a fallback for tokens whose `exp` we can't read; on its own it forced a
    /// refresh while the access token was still valid, tripping `refresh_token_reused` (issue #516).
    /// A brand-new login with no `last_refresh` and no readable `exp` does NOT need a refresh.
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiresAt(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = OpenUsageISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    /// The access token's expiry from its JWT `exp` claim, or `nil` when the token isn't a decodable
    /// JWT or omits `exp`.
    func accessTokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func authPaths() -> [String] {
        // A scoped store reads only its own pinned home (or no file at all for a keychain-only
        // account) — never the env override or the default homes.
        if let account {
            return account.configDir.map { [joinPath($0, Self.authFile)] } ?? []
        }
        if let codexHome = codexHome() {
            return [joinPath(codexHome, Self.authFile)]
        }
        return Self.defaultAuthHomes.map { joinPath($0, Self.authFile) }
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self)
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        if auth.apiKey?.isEmpty == false { return true }
        return false
    }

    private func joinPath(_ base: String, _ leaf: String) -> String {
        base.trimmingTrailingSlashes + "/" + leaf
    }
}

private extension CodexAuthState.Source {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

