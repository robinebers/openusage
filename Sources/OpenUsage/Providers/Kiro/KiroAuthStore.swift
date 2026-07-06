import Foundation

struct KiroAuth: Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var profileArn: String?
}

enum KiroAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Kiro. Run `kiro-cli login` and try again."
        case .tokenExpired:
            return "Kiro session expired. Run `kiro-cli login` and try again."
        }
    }
}

struct KiroAuthStore: Sendable {
    /// kiro-cli on macOS stores its SQLite database in Application Support.
    static let stateDBPath = "~/Library/Application Support/kiro-cli/data.sqlite3"

    /// Key in `auth_kv` table that stores the social (GitHub/Google/Builder ID) token JSON.
    static let socialTokenKey = "kirocli:social:token"

    /// Key in `state` table that stores the CodeWhisperer profile ARN JSON.
    static let profileArnKey = "api.codewhisperer.profile"

    var sqlite: SQLiteAccessing

    init(sqlite: SQLiteAccessing = SQLiteCLIAccessor()) {
        self.sqlite = sqlite
    }

    func loadAuth() -> KiroAuth? {
        guard let tokenJSON = readAuthKVValue(Self.socialTokenKey),
              let tokenData = tokenJSON.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: tokenData)) as? [String: Any],
              let accessToken = (parsed["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            return nil
        }

        let refreshToken = (parsed["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Profile ARN is stored separately in the `state` table.
        let profileArn = loadProfileArn()

        return KiroAuth(accessToken: accessToken, refreshToken: refreshToken, profileArn: profileArn)
    }

    private func loadProfileArn() -> String? {
        guard let profileJSON = readStateValue(Self.profileArnKey),
              let profileData = profileJSON.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: profileData)) as? [String: Any],
              let arn = (parsed["arn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !arn.isEmpty
        else {
            return nil
        }
        return arn
    }

    private func readAuthKVValue(_ key: String) -> String? {
        let escaped = Self.sqlEscaped(key)
        let sql = "SELECT value FROM auth_kv WHERE key = '\(escaped)' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readStateValue(_ key: String) -> String? {
        let escaped = Self.sqlEscaped(key)
        let sql = "SELECT value FROM state WHERE key = '\(escaped)' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
