import Foundation

struct KiroAuth: Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var profileArn: String?
    var region: String
    var authType: KiroAuthType
    var clientId: String?
    var clientSecret: String?
}

enum KiroAuthType: String, Sendable, Hashable {
    case social
    case oidc
}

enum KiroAuthError: Error, LocalizedError, Equatable, CategorizedError {
    case notLoggedIn
    case missingProfileArn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to Kiro IDE or run kiro-cli login, then refresh."
        case .missingProfileArn:
            return "Kiro profile not found. Open Kiro IDE and sign in, then refresh."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .missingProfileArn: .authInvalid
        }
    }
}

/// Reads Kiro credentials already on the user's machine. The Kiro IDE's social login stores a token at
/// `~/.aws/sso/cache/kiro-auth-token.json`; the kiro-cli's OIDC login stores its token in a SQLite
/// database at `~/Library/Application Support/kiro-cli/data.sqlite3`. The IDE path is checked first
/// (the primary source); the CLI database is the last-resort fallback, per the user's preference.
///
/// A profile ARN is required to call the usage API. It comes from the token file directly, from a
/// separate `profile.json` the IDE writes, or from the CLI database's `state` table.
struct KiroAuthStore: Sendable {
    static let tokenFilePath = "~/.aws/sso/cache/kiro-auth-token.json"
    static let profilePath = "~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/profile.json"
    static let cliDBPath = "~/Library/Application Support/kiro-cli/data.sqlite3"
    static let defaultRegion = "us-east-1"

    /// Token keys in the CLI database's `auth_kv` table, checked in priority order.
    static let cliTokenKeys = [
        "kirocli:social:token",
        "kirocli:odic:token",
        "kirocli:oidc:token",
        "codewhisperer:odic:token",
        "codewhisperer:oidc:token",
    ]

    /// Device-registration keys in the CLI database's `auth_kv` table (for OIDC token refresh).
    static let cliDeviceRegistrationKeys = [
        "kirocli:social:device-registration",
        "kirocli:odic:device-registration",
        "kirocli:oidc:device-registration",
        "codewhisperer:odic:device-registration",
        "codewhisperer:oidc:device-registration",
        "kirocli:social:device_registration",
        "kirocli:odic:device_registration",
        "kirocli:oidc:device_registration",
        "codewhisperer:odic:device_registration",
        "codewhisperer:oidc:device_registration",
    ]

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    // MARK: - IDE token file (primary)

    func loadTokenFile() -> KiroAuth? {
        guard let text = try? files.readTextIfPresent(Self.tokenFilePath),
              let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = (json["accessToken"] as? String)?.nilIfEmpty
        else {
            return nil
        }

        let refreshToken = (json["refreshToken"] as? String)?.nilIfEmpty
        let profileArn = (json["profileArn"] as? String)?.nilIfEmpty
        let region = (json["region"] as? String)?.nilIfEmpty ?? Self.defaultRegion

        return KiroAuth(
            accessToken: accessToken,
            refreshToken: refreshToken,
            profileArn: profileArn,
            region: region,
            authType: .social,
            clientId: nil,
            clientSecret: nil
        )
    }

    // MARK: - CLI SQLite database (last priority)

    func loadCLIToken() -> KiroAuth? {
        for key in Self.cliTokenKeys {
            let sql = "SELECT value FROM auth_kv WHERE key = '\(key)' LIMIT 1"
            guard let value = try? sqlite.queryValue(path: Self.cliDBPath, sql: sql),
                  let valueData = value.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: valueData)) as? [String: Any],
                  let accessToken = coalesce(json["accessToken"], json["access_token"])?.nilIfEmpty
            else {
                continue
            }

            let refreshToken = coalesce(json["refreshToken"], json["refresh_token"])?.nilIfEmpty
            let region = (json["region"] as? String)?.nilIfEmpty ?? Self.defaultRegion
            let authType: KiroAuthType = key.contains("social") ? .social : .oidc

            var clientId: String?
            var clientSecret: String?
            if authType == .oidc {
                (clientId, clientSecret) = loadDeviceRegistration()
            }

            let profileArn = loadCLIProfileArn()

            return KiroAuth(
                accessToken: accessToken,
                refreshToken: refreshToken,
                profileArn: profileArn,
                region: region,
                authType: authType,
                clientId: clientId,
                clientSecret: clientSecret
            )
        }

        return nil
    }

    // MARK: - Profile ARN

    func loadProfileFile() -> String? {
        guard let text = try? files.readTextIfPresent(Self.profilePath),
              let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arn = (json["arn"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return arn
    }

    private func loadCLIProfileArn() -> String? {
        let sql = "SELECT value FROM state WHERE key = 'api.codewhisperer.profile' LIMIT 1"
        return try? sqlite.queryValue(path: Self.cliDBPath, sql: sql)
    }

    private func loadDeviceRegistration() -> (String?, String?) {
        for key in Self.cliDeviceRegistrationKeys {
            let sql = "SELECT value FROM auth_kv WHERE key = '\(key)' LIMIT 1"
            guard let value = try? sqlite.queryValue(path: Self.cliDBPath, sql: sql),
                  let valueData = value.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: valueData)) as? [String: Any]
            else {
                continue
            }
            let clientId = coalesce(json["clientId"], json["client_id"])?.nilIfEmpty
            let clientSecret = coalesce(json["clientSecret"], json["client_secret"])?.nilIfEmpty
            if clientId != nil || clientSecret != nil {
                return (clientId, clientSecret)
            }
        }
        return (nil, nil)
    }

    // MARK: - Effective profile ARN

    /// Resolve the profile ARN from the auth itself, the IDE profile file, or the CLI database.
    func effectiveProfileArn(_ auth: KiroAuth) -> String? {
        if let arn = auth.profileArn { return arn }
        if let arn = loadProfileFile() { return arn }
        if let arn = loadCLIProfileArn() { return arn }
        return nil
    }

    // MARK: - Helpers

    private func coalesce(_ a: Any?, _ b: Any?) -> String? {
        if let s = a as? String { return s }
        if let s = b as? String { return s }
        return nil
    }
}
