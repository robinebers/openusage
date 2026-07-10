import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialStoreUnreadable
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .credentialStoreUnreadable:
            return "Couldn't read Cursor credentials. Check access to Cursor's local app data and Keychain, then try again."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    /// Load every local source before deciding the result. `nil` is reserved for a proven miss across
    /// the state database and Keychain; an authentication-field read failure throws only when no
    /// usable sibling state exists. Optional membership metadata never decides credential availability.
    func loadAuthState() throws -> CursorAuthState? {
        var failures = CredentialLoadFailures()
        let sqliteAccessToken = readStateValue(Self.accessTokenKey, failures: &failures)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey, failures: &failures)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey, failures: &failures)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService, failures: &failures)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService, failures: &failures)

        let sqliteState = CursorAuthState(
            accessToken: sqliteAccessToken,
            refreshToken: sqliteRefreshToken,
            source: .sqlite
        )
        let keychainState = CursorAuthState(
            accessToken: keychainAccessToken,
            refreshToken: keychainRefreshToken,
            source: .keychain
        )
        let sqliteReadiness = authReadiness(
            accessToken: sqliteAccessToken,
            refreshToken: sqliteRefreshToken,
            accessReadFailed: failures.failedStateKeys.contains(Self.accessTokenKey),
            refreshReadFailed: failures.failedStateKeys.contains(Self.refreshTokenKey)
        )
        let keychainReadiness = authReadiness(
            accessToken: keychainAccessToken,
            refreshToken: keychainRefreshToken,
            accessReadFailed: failures.failedKeychainServices.contains(Self.keychainAccessTokenService),
            refreshReadFailed: failures.failedKeychainServices.contains(Self.keychainRefreshTokenService)
        )

        switch sqliteReadiness {
        case .usable:
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if keychainReadiness == .usable, sqliteMembershipType == "free", subjectsDiffer {
                return keychainState
            }
            return sqliteState
        case .expired:
            switch keychainReadiness {
            case .usable: return keychainState
            case .unreadable: throw CursorAuthError.credentialStoreUnreadable
            case .absent, .expired: return sqliteState
            }
        case .unreadable:
            guard keychainReadiness != .usable else { return keychainState }
            throw CursorAuthError.credentialStoreUnreadable
        case .absent:
            switch keychainReadiness {
            case .usable, .expired: return keychainState
            case .unreadable: throw CursorAuthError.credentialStoreUnreadable
            case .absent: return nil
            }
        }
    }

    private enum AuthReadiness: Equatable {
        case absent
        case usable
        case expired
        case unreadable
    }

    /// Classify only what can be proven locally. Refresh material makes a source usable even if its
    /// access-token read failed. Opaque access tokens remain potentially usable because only Cursor can
    /// validate them. A known-expired token needs a refresh token; failure to read that token is a store
    /// error, while a proven missing refresh token is an ordinary expired session.
    private func authReadiness(
        accessToken: String?,
        refreshToken: String?,
        accessReadFailed: Bool,
        refreshReadFailed: Bool
    ) -> AuthReadiness {
        if refreshToken != nil { return .usable }
        if let accessToken {
            if let expiresAt = Self.tokenExpiration(accessToken), expiresAt <= now() {
                return refreshReadFailed ? .unreadable : .expired
            }
            return .usable
        }
        return accessReadFailed || refreshReadFailed ? .unreadable : .absent
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorAuthState.Source) throws {
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        }
    }

    private struct CredentialLoadFailures {
        var failedStateKeys: Set<String> = []
        var failedKeychainServices: Set<String> = []
        private var loggedSources: Set<String> = []

        mutating func recordStateKey(_ key: String) {
            failedStateKeys.insert(key)
            record(source: "state database")
        }

        mutating func recordKeychainService(_ service: String) {
            failedKeychainServices.insert(service)
            record(source: "Keychain")
        }

        mutating func record(source: String) {
            if loggedSources.insert(source).inserted {
                AppLog.error(LogTag.auth("cursor"), "\(source) credential read failed")
            }
        }
    }

    private func readStateValue(_ key: String, failures: inout CredentialLoadFailures) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        let value: String?
        do {
            value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql)
        } catch {
            failures.recordStateKey(key)
            return nil
        }
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String, failures: inout CredentialLoadFailures) -> String? {
        let value: String?
        do {
            value = try keychain.readGenericPassword(service: service)
        } catch {
            failures.recordKeychainService(service)
            return nil
        }
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
