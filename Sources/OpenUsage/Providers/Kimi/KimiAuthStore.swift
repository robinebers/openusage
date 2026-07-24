import Foundation

/// The OAuth token the Kimi Code CLI leaves in its credentials file.
///
/// `expiresAt` is epoch **seconds** here — Claude's equivalent is milliseconds, so don't carry that
/// arithmetic across. Access tokens are short-lived (~15 minutes), which is why this provider refreshes
/// rather than only borrowing a valid token.
struct KimiOAuth: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var expiresIn: Double?
    var scope: String?
    var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

/// A loaded credential plus the home it came from, so a rotation is written back to the same file it was
/// read from rather than to whichever home happens to be first in precedence order.
struct KimiAuthState: Hashable, Sendable {
    var home: String
    var oauth: KimiOAuth
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidCredentials
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `kimi` to authenticate."
        case .invalidCredentials:
            return "Kimi credentials couldn't be read. Run `kimi` to log in again."
        case .sessionExpired:
            return "Session expired. Run `kimi` to log in again."
        case .tokenExpired:
            return "Token expired. Run `kimi` to log in again."
        }
    }
}

/// Reads (and rotates) the OAuth token the Kimi Code CLI already stores on the machine. No login flow of
/// its own, no browser, no Keychain — the CLI deprecated keyring storage and migrated to a 0600 JSON file.
struct KimiAuthStore: Sendable {
    static let credentialsFileName = "kimi-code.json"
    static let lockFileName = "kimi-code.lock"
    /// The shipped Kimi Code CLI's data root (`KIMI_CODE_HOME`).
    static let defaultCodeHome = "~/.kimi-code"
    /// The upstream CLI's data root (`KIMI_SHARE_DIR`). Both layouts are in the wild, so both are read.
    static let defaultShareHome = "~/.kimi"
    static let refreshBuffer: TimeInterval = 5 * 60

    var files: TextFileAccessing
    var environment: EnvironmentReading
    var lock: any FileLocking
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        lock: any FileLocking = LocalFileLock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.environment = environment
        self.lock = lock
        self.now = now
    }

    /// Candidate data roots in precedence order: each env override before its default, and the shipped
    /// CLI's layout before upstream's.
    func homes() -> [String] {
        var result: [String] = []
        func append(_ path: String?) {
            guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return }
            let normalized = trimmed.trimmingTrailingSlashes
            guard !normalized.isEmpty, !result.contains(normalized) else { return }
            result.append(normalized)
        }
        append(environment.value(for: "KIMI_CODE_HOME"))
        append(Self.defaultCodeHome)
        append(environment.value(for: "KIMI_SHARE_DIR"))
        append(Self.defaultShareHome)
        return result
    }

    func credentialsPath(inHome home: String) -> String {
        "\(home)/credentials/\(Self.credentialsFileName)"
    }

    func lockPath(inHome home: String) -> String {
        "\(home)/credentials/\(Self.lockFileName)"
    }

    /// The first home holding a usable token. `nil` means no Kimi login exists on this machine; a
    /// credentials file that exists but can't be parsed throws, so broken storage surfaces as an
    /// actionable error instead of masquerading as "not logged in".
    func load() throws -> KimiAuthState? {
        var sawUnreadable = false
        for home in homes() {
            let path = credentialsPath(inHome: home)
            guard let text = try files.readTextIfPresent(path) else { continue }
            guard let oauth = Self.parse(text),
                  !oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                sawUnreadable = true
                continue
            }
            return KimiAuthState(home: home, oauth: oauth)
        }
        if sawUnreadable { throw KimiAuthError.invalidCredentials }
        return nil
    }

    /// Whether a Kimi credentials file exists at all, without parsing it — the local-only probe behind
    /// first-run and new-provider detection. A present-but-unreadable file still counts as a footprint so
    /// `refresh()` gets to report the real problem rather than the provider staying invisibly off.
    func hasCredentialsFile() -> Bool {
        homes().contains { files.exists(credentialsPath(inHome: $0)) }
    }

    /// Whether the access token is close enough to expiry to refresh pre-emptively. A credential with no
    /// `expires_at` is left alone: rotating another tool's refresh token on a guess is the one thing worth
    /// avoiding here, and `ProviderAuthRetry` still recovers reactively from a 401.
    func needsRefresh(_ oauth: KimiOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt).timeIntervalSince(now()) <= Self.refreshBuffer
    }

    func refreshToken(for oauth: KimiOAuth) -> String? {
        oauth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Re-read the live credential for `home`, so a token the CLI rotated since we loaded ours is adopted
    /// instead of refreshed from our stale copy — sending an already-rotated refresh token is how you trip
    /// the server's replay detection and log the user out.
    func reloadLive(home: String) -> KimiAuthState? {
        guard let text = try? files.readTextIfPresent(credentialsPath(inHome: home)),
              let oauth = Self.parse(text),
              !oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return KimiAuthState(home: home, oauth: oauth)
    }

    /// Persist a rotated token pair back into the Kimi CLI's own credentials file.
    ///
    /// Held under an exclusive `flock` on `credentials/kimi-code.lock` — the same lock file the CLI's own
    /// cross-process refresh takes — so a concurrent `kimi` refresh and ours can't rotate from the same
    /// refresh token. Inside the lock the live file is re-read and merged into as a raw dictionary, so
    /// fields OpenUsage doesn't model survive the round-trip, and a present-but-corrupt file throws rather
    /// than being rebuilt from memory (which would drop whatever else it held).
    func save(_ state: KimiAuthState) throws {
        let path = credentialsPath(inHome: state.home)
        try lock.withExclusiveLock(at: lockPath(inHome: state.home)) {
            var object: [String: Any]
            if files.exists(path) {
                guard let text = try? files.readText(path),
                      let parsed = Self.parseJSONObject(text)
                else {
                    throw KimiAuthError.invalidCredentials
                }
                object = parsed
            } else {
                object = [:]
            }

            object["access_token"] = state.oauth.accessToken
            if let refreshToken = state.oauth.refreshToken { object["refresh_token"] = refreshToken }
            if let expiresAt = state.oauth.expiresAt { object["expires_at"] = expiresAt }
            if let expiresIn = state.oauth.expiresIn { object["expires_in"] = expiresIn }
            if let scope = state.oauth.scope { object["scope"] = scope }
            if let tokenType = state.oauth.tokenType { object["token_type"] = tokenType }

            guard JSONSerialization.isValidJSONObject(object) else {
                throw KimiAuthError.invalidCredentials
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw KimiAuthError.invalidCredentials
            }
            try files.writeText(path, text)
        }
    }

    static func parse(_ text: String) -> KimiOAuth? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KimiOAuth.self, from: data)
    }

    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
