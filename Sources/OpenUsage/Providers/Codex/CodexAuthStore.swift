import CryptoKit
import Foundation

/// Which login a `CodexAuthStore` is allowed to see. `.standard` is the default card — it follows env
/// `CODEX_HOME`, then the two historical default homes, and targets each home's computed keychain
/// account rather than performing an ambiguous service-only read. `.home` backs a provider instance
/// pinned to exactly one Codex home: its `auth.json` plus its
/// per-home keychain item (`Codex Auth`, account `cli|<first 16 hex of SHA-256 of the canonical home
/// path>` — the CLI's own keyring naming), with no environment fallback.
enum CodexCredentialScope: Hashable, Sendable {
    case standard
    case home(path: String)
}

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
    /// Exact keychain account loaded for this state. Carried through refresh so a token rotation
    /// updates that same item even when several `Codex Auth` items coexist.
    var keychainAccount: String?
    /// Canonical home behind either source, used only to update the local opaque identity cache.
    var credentialHome: String?

    init(
        auth: CodexAuth,
        source: Source,
        keychainAccount: String? = nil,
        credentialHome: String? = nil
    ) {
        self.auth = auth
        self.source = source
        self.keychainAccount = keychainAccount
        self.credentialHome = credentialHome
    }

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
    var identityCache: (any CodexHomeIdentityCaching)?
    var now: @Sendable () -> Date
    let scope: CodexCredentialScope

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        scope: CodexCredentialScope = .standard,
        identityCache: (any CodexHomeIdentityCaching)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.scope = scope
        self.identityCache = identityCache
        self.now = now
    }

    func loadAuthCandidates() -> [CodexAuthState] {
        authPaths().compactMap { loadAuth(at: $0) }
    }

    /// The keychain account name the Codex CLI's keyring mode uses for a given home: `cli|` plus the
    /// first 16 hex of SHA-256 of the canonicalized home path. Computable both ways we need it — from
    /// a discovered dir (existence probe) and from a scoped store (secret read) — so there is never a
    /// reason to enumerate the service.
    static func keychainAccountName(forHome path: String) -> String {
        let canonical = URL(fileURLWithPath: expandHome(path))
            .resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|\(hex.prefix(16))"
    }

    /// Footprint-only credential presence for a scoped instance (file exists, or its computed keychain
    /// item exists by attributes) — never reads a secret, so seeding can't raise a permission dialog.
    func hasCredentialFootprint() -> Bool {
        switch scope {
        case .standard:
            return !loadAuthCandidates().isEmpty || credentialHomes().contains { home in
                keychain.hasGenericPassword(
                    service: Self.keychainService,
                    account: Self.keychainAccountName(forHome: home)
                )
            }
        case .home(let path):
            if files.exists(joinPath(path, Self.authFile)) { return true }
            return keychain.hasGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccountName(forHome: path)
            )
        }
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
        let home = Self.canonicalHome(forAuthPath: path)
        // Discovery can read file identities directly, so don't persist a keyring cache binding while
        // merely enumerating file candidates. A standard store can load two files before probing either,
        // and only the successful candidate owns the default card.
        _ = recordResolvedIdentity(
            auth,
            home: home,
            cacheKeychainIdentity: false
        )
        return CodexAuthState(auth: auth, source: .file(path: path), credentialHome: home)
    }

    func loadKeychainAuth() -> CodexAuthState? {
        // Every candidate is account-scoped. The standard card follows the same home order as
        // `authPaths()`, so an unrelated instance item under the shared service can never win an
        // unspecified keychain query.
        for home in credentialHomes() {
            let account = Self.keychainAccountName(forHome: home)
            guard let value = try? keychain.readGenericPassword(
                service: Self.keychainService,
                account: account
            ),
                let auth = Self.parseAuth(value),
                Self.hasTokenLikeAuth(auth)
            else { continue }
            let canonicalHome = ProviderInstanceID.canonicalHomePath(home)
            _ = recordResolvedIdentity(
                auth,
                home: canonicalHome,
                cacheKeychainIdentity: true
            )
            return CodexAuthState(
                auth: auth,
                source: .keychain,
                keychainAccount: account,
                credentialHome: canonicalHome
            )
        }
        return nil
    }

    /// Re-read the exact credential that produced `state`. The default scope can know several
    /// homes, so repeating the normal precedence walk during token rotation could jump from the
    /// selected account to a different Keychain item that appeared earlier in the list.
    func reload(_ state: CodexAuthState) -> CodexAuthState? {
        switch state.source {
        case .file(let path):
            return loadAuth(at: path)
        case .keychain:
            guard let account = state.keychainAccount,
                  let home = state.credentialHome,
                  let value = try? keychain.readGenericPassword(
                      service: Self.keychainService,
                      account: account
                  ),
                  let auth = Self.parseAuth(value),
                  Self.hasTokenLikeAuth(auth)
            else { return nil }
            _ = recordResolvedIdentity(
                auth,
                home: home,
                cacheKeychainIdentity: true
            )
            return CodexAuthState(
                auth: auth,
                source: .keychain,
                keychainAccount: account,
                credentialHome: home
            )
        }
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
            guard let account = state.keychainAccount else {
                // Keychain states can only originate in `loadKeychainAuth()`. Refuse an unscoped
                // write instead of recreating the service-only ambiguity this type prevents.
                throw CodexAuthError.invalidAuthPayload
            }
            try keychain.writeGenericPassword(
                service: Self.keychainService,
                account: account,
                value: text
            )
        }
        if let home = state.credentialHome {
            _ = recordResolvedIdentity(
                state.auth,
                home: home,
                cacheKeychainIdentity: state.source.isKeychain
            )
        }
    }

    /// Marks the credential that actually completed a usage probe. File candidates are enumerated
    /// before probing, so emitting while loading them could transiently bind the default card to a
    /// candidate that later fails. The provider calls this only after the API accepts the candidate,
    /// which also resolves an otherwise ambiguous two-default-home launch in the same refresh.
    @discardableResult
    func recordSelectedIdentity(_ state: CodexAuthState) -> String? {
        guard let home = state.credentialHome else { return nil }
        return recordResolvedIdentity(
            state.auth,
            home: home,
            cacheKeychainIdentity: state.source.isKeychain
        )
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
        credentialHomes().map { joinPath($0, Self.authFile) }
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    /// Homes in credential precedence order. Comma-separated `CODEX_HOME` values already drive the
    /// log scanner and discovery, so auth uses that same order instead of treating the whole list as
    /// one impossible directory name.
    func credentialHomes() -> [String] {
        if case .home(let path) = scope { return [path] }
        if let raw = codexHome() {
            let homes = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !homes.isEmpty { return homes }
        }
        return Self.defaultAuthHomes
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

    private static func canonicalHome(forAuthPath path: String) -> String {
        URL(fileURLWithPath: expandHome(path))
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    @discardableResult
    private func recordResolvedIdentity(
        _ auth: CodexAuth,
        home: String,
        cacheKeychainIdentity: Bool
    ) -> String? {
        guard let identityKey = auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identityKey.isEmpty
        else { return nil }
        if cacheKeychainIdentity {
            let account = Self.keychainAccountName(forHome: home)
            if let fingerprint = keychain.genericPasswordAttributeFingerprint(
                service: Self.keychainService,
                account: account
            ) {
                identityCache?.record(
                    identityKey: identityKey,
                    forHome: home,
                    keychainItemFingerprint: fingerprint
                )
            } else {
                AppLog.warn(
                    .keychain,
                    "Codex identity cache skipped because the account-scoped item attributes were unreadable"
                )
            }
        }
        return identityKey
    }
}

private extension CodexAuthState.Source {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    var isKeychain: Bool {
        if case .keychain = self { return true }
        return false
    }
}
