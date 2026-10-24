import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    /// Lowercased `cursorAuth/stripeMembershipType` from the Cursor state DB when present.
    var membershipType: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
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
    var safeStorageKey: any CursorSafeStorageKeyReading
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        safeStorageKey: any CursorSafeStorageKeyReading = CursorSafeStorageKeyReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.safeStorageKey = safeStorageKey
        self.now = now
    }

    func loadAuthState() -> CursorAuthState? {
        let editorTokens = usableEditorTokens(
            access: readStateValue(Self.accessTokenKey),
            refresh: readStateValue(Self.refreshTokenKey)
        )
        let sqliteAccessToken = editorTokens.access
        let sqliteRefreshToken = editorTokens.refresh
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                // SQLite looks like a free account for a different subject; do not carry that
                // membership onto the keychain session.
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    membershipType: nil,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                membershipType: sqliteMembershipType,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            // Keychain-only auth has no proven link to the state-DB membership row; leave it unset
            // rather than attaching another account's stripeMembershipType.
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                membershipType: nil,
                source: .keychain
            )
        }

        return nil
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
            if let existing = readStateValue(Self.accessTokenKey), CursorSealedToken.isSealed(existing) {
                guard let password = try safeStorageKey.readPassword() else {
                    throw CursorSealedTokenError.missingKey
                }
                try writeStateValue(Self.accessTokenKey, CursorSealedToken.seal(token: accessToken, password: password))
            } else {
                try writeStateValue(Self.accessTokenKey, accessToken)
            }
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        }
    }

    /// Plaintext JWTs pass through. Sealed cells are opened with the safeStorage
    /// password, once for the pair. A cell that cannot be opened becomes nil so
    /// it is never sent to Cursor as a refresh token (`shouldLogout`), and the
    /// CLI keychain login can still be used.
    private func usableEditorTokens(access: String?, refresh: String?) -> (access: String?, refresh: String?) {
        let needsKey = [access, refresh].compactMap { $0 }.contains(where: CursorSealedToken.isSealed)
        guard needsKey else { return (access, refresh) }

        let password: String?
        do {
            password = try safeStorageKey.readPassword()
        } catch {
            AppLog.warn(LogTag.auth("cursor"), "Cursor Safe Storage key could not be read")
            password = nil
        }
        func open(_ stored: String?) -> String? {
            guard let stored else { return nil }
            guard CursorSealedToken.isSealed(stored) else { return stored }
            guard let password else { return nil }
            return CursorSealedToken.open(stored: stored, password: password)
        }
        let opened = (open(access), open(refresh))
        let failed = (access.map(CursorSealedToken.isSealed) == true && opened.0 == nil)
            || (refresh.map(CursorSealedToken.isSealed) == true && opened.1 == nil)
        if failed {
            let reason = password == nil
                ? "Cursor login is sealed and the Safe Storage key is unavailable"
                : "Cursor login is sealed and the Safe Storage key could not open it"
            AppLog.warn(LogTag.auth("cursor"), reason)
        }
        return opened
    }

    private func readStateValue(_ key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
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
