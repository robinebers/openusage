import XCTest
@testable import OpenUsage

final class CursorCredentialBoundaryTests: XCTestCase {
    func testMissingCredentialSourcesAreProvenAbsent() throws {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(),
            keychain: CursorBoundaryKeychain()
        )

        XCTAssertNil(try store.loadAuthState())
    }

    func testUnreadableStateDatabaseThrowsCredentialStoreUnreadable() {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(failAllQueries: true),
            keychain: CursorBoundaryKeychain()
        )

        XCTAssertThrowsError(try store.loadAuthState()) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialStoreUnreadable)
        }
    }

    func testUnreadableKeychainThrowsCredentialStoreUnreadable() {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(),
            keychain: CursorBoundaryKeychain(failAllReads: true)
        )

        XCTAssertThrowsError(try store.loadAuthState()) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialStoreUnreadable)
        }
    }

    func testValidKeychainStateWinsWhenStateDatabaseIsUnreadable() throws {
        let keychain = CursorBoundaryKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: "keychain-access",
            CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
        ])
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(failAllQueries: true),
            keychain: keychain
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state, CursorAuthState(
            accessToken: "keychain-access",
            refreshToken: "keychain-refresh",
            source: .keychain
        ))
    }

    func testValidSQLiteStateWinsWhenKeychainIsUnreadable() throws {
        let sqlite = CursorBoundarySQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-access",
            CursorAuthStore.refreshTokenKey: "sqlite-refresh"
        ])
        let store = CursorAuthStore(
            sqlite: sqlite,
            keychain: CursorBoundaryKeychain(failAllReads: true)
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state, CursorAuthState(
            accessToken: "sqlite-access",
            refreshToken: "sqlite-refresh",
            source: .sqlite
        ))
    }

    func testValidSQLiteTokenWinsWhenMembershipReadFails() throws {
        let sqlite = CursorBoundarySQLite(
            values: [CursorAuthStore.accessTokenKey: "sqlite-access"],
            failingKeys: [CursorAuthStore.membershipTypeKey]
        )
        let store = CursorAuthStore(sqlite: sqlite, keychain: CursorBoundaryKeychain())

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.accessToken, "sqlite-access")
        XCTAssertEqual(state?.source, .sqlite)
    }

    func testMembershipReadFailureIsNonTerminalWhenAuthFieldsAreAbsent() throws {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(failingKeys: [CursorAuthStore.membershipTypeKey]),
            keychain: CursorBoundaryKeychain()
        )

        XCTAssertNil(try store.loadAuthState())
    }

    func testUsableKeychainWinsWhenExpiredSQLiteCannotReadRefreshToken() throws {
        let keychainAccess = cursorBoundaryJWT(subject: "google-oauth2|keychain-user")
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(
                values: [
                    CursorAuthStore.accessTokenKey:
                        cursorBoundaryJWT(subject: "google-oauth2|sqlite-user", expiration: 1)
                ],
                failingKeys: [CursorAuthStore.refreshTokenKey]
            ),
            keychain: CursorBoundaryKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: keychainAccess
            ]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainAccess)
    }

    func testEquallyIncompleteKeychainDoesNotDisplacePreferredSQLiteState() throws {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(
                values: [CursorAuthStore.accessTokenKey: "sqlite-opaque-token"],
                failingKeys: [CursorAuthStore.refreshTokenKey]
            ),
            keychain: CursorBoundaryKeychain(
                values: [CursorAuthStore.keychainAccessTokenService: "keychain-opaque-token"],
                failingServices: [CursorAuthStore.keychainRefreshTokenService]
            )
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, "sqlite-opaque-token")
    }

    func testOpaqueKeychainReplacesExpiredSQLiteWhenBothRefreshReadsFail() throws {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(
                values: [
                    CursorAuthStore.accessTokenKey:
                        cursorBoundaryJWT(subject: "google-oauth2|sqlite-user", expiration: 1)
                ],
                failingKeys: [CursorAuthStore.refreshTokenKey]
            ),
            keychain: CursorBoundaryKeychain(
                values: [CursorAuthStore.keychainAccessTokenService: "keychain-opaque-token"],
                failingServices: [CursorAuthStore.keychainRefreshTokenService]
            ),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, "keychain-opaque-token")
    }

    func testUnexpiredSQLiteAccessStillWinsWhenRefreshReadFails() throws {
        let sqliteAccess = cursorBoundaryJWT(subject: "google-oauth2|sqlite-user")
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(
                values: [CursorAuthStore.accessTokenKey: sqliteAccess],
                failingKeys: [CursorAuthStore.refreshTokenKey]
            ),
            keychain: CursorBoundaryKeychain(values: [
                CursorAuthStore.keychainAccessTokenService:
                    cursorBoundaryJWT(subject: "google-oauth2|keychain-user")
            ]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, sqliteAccess)
    }

    func testValidKeychainRefreshTokenWinsWhenAccessTokenReadFails() throws {
        let keychain = CursorBoundaryKeychain(
            values: [CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"],
            failingServices: [CursorAuthStore.keychainAccessTokenService]
        )
        let store = CursorAuthStore(sqlite: CursorBoundarySQLite(), keychain: keychain)

        let state = try store.loadAuthState()

        XCTAssertNil(state?.accessToken)
        XCTAssertEqual(state?.refreshToken, "keychain-refresh")
        XCTAssertEqual(state?.source, .keychain)
    }

    func testBlankOpaqueValuesRemainAbsent() throws {
        let store = CursorAuthStore(
            sqlite: CursorBoundarySQLite(values: [
                CursorAuthStore.accessTokenKey: "  ",
                CursorAuthStore.refreshTokenKey: "\n"
            ]),
            keychain: CursorBoundaryKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: "\t",
                CursorAuthStore.keychainRefreshTokenService: " "
            ])
        )

        XCTAssertNil(try store.loadAuthState())
    }

    func testEverySourceIsCheckedBeforeAReadFailureSurfaces() {
        let sqlite = CursorBoundarySQLite(failAllQueries: true)
        let keychain = CursorBoundaryKeychain(failAllReads: true)
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        XCTAssertThrowsError(try store.loadAuthState())

        XCTAssertEqual(Set(sqlite.queriedKeys), Set([
            CursorAuthStore.accessTokenKey,
            CursorAuthStore.refreshTokenKey,
            CursorAuthStore.membershipTypeKey
        ]))
        XCTAssertEqual(Set(keychain.readServices), Set([
            CursorAuthStore.keychainAccessTokenService,
            CursorAuthStore.keychainRefreshTokenService
        ]))
    }

    @MainActor
    func testCredentialProbeAndRefreshDistinguishAbsentAndUnreadableSources() async {
        let absent = makeCursorBoundaryProvider(
            sqlite: CursorBoundarySQLite(),
            keychain: CursorBoundaryKeychain()
        )
        let absentDetected = await absent.hasLocalCredentials()
        XCTAssertFalse(absentDetected)
        let absentSnapshot = await absent.refresh()
        XCTAssertEqual(absentSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(cursorBoundaryErrorText(absentSnapshot), CursorAuthError.notLoggedIn.localizedDescription)

        let unreadableDatabase = makeCursorBoundaryProvider(
            sqlite: CursorBoundarySQLite(failAllQueries: true),
            keychain: CursorBoundaryKeychain()
        )
        let databaseDetected = await unreadableDatabase.hasLocalCredentials()
        XCTAssertTrue(databaseDetected)
        let databaseSnapshot = await unreadableDatabase.refresh()
        XCTAssertEqual(databaseSnapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(
            cursorBoundaryErrorText(databaseSnapshot),
            CursorAuthError.credentialStoreUnreadable.localizedDescription
        )

        let unreadableKeychain = makeCursorBoundaryProvider(
            sqlite: CursorBoundarySQLite(),
            keychain: CursorBoundaryKeychain(failAllReads: true)
        )
        let keychainDetected = await unreadableKeychain.hasLocalCredentials()
        XCTAssertTrue(keychainDetected)
        let keychainSnapshot = await unreadableKeychain.refresh()
        XCTAssertEqual(keychainSnapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(
            cursorBoundaryErrorText(keychainSnapshot),
            CursorAuthError.credentialStoreUnreadable.localizedDescription
        )
    }

    @MainActor
    func testExpiredAccessWithUnreadableRefreshSurfacesCredentialStoreErrorForEitherStore() async {
        let expired = cursorBoundaryJWT(subject: "google-oauth2|expired", expiration: 1)
        let providers = [
            makeCursorBoundaryProvider(
                sqlite: CursorBoundarySQLite(
                    values: [CursorAuthStore.accessTokenKey: expired],
                    failingKeys: [CursorAuthStore.refreshTokenKey]
                ),
                keychain: CursorBoundaryKeychain()
            ),
            makeCursorBoundaryProvider(
                sqlite: CursorBoundarySQLite(),
                keychain: CursorBoundaryKeychain(
                    values: [CursorAuthStore.keychainAccessTokenService: expired],
                    failingServices: [CursorAuthStore.keychainRefreshTokenService]
                )
            )
        ]

        for provider in providers {
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
            XCTAssertEqual(
                cursorBoundaryErrorText(snapshot),
                CursorAuthError.credentialStoreUnreadable.localizedDescription
            )
        }
    }

    @MainActor
    func testRefreshUsesValidKeychainDespiteUnreadableStateDatabase() async {
        let accessToken = cursorBoundaryJWT(subject: "google-oauth2|boundary-user")
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: CursorBoundarySQLite(failAllQueries: true),
                keychain: CursorBoundaryKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: accessToken
                ])
            ),
            usageClient: CursorUsageClient(http: cursorBoundaryHTTP(accessToken: accessToken)),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
    }

    @MainActor
    func testRefreshUsesKeychainWhenExpiredSQLiteCannotReadRefreshToken() async {
        let sqliteAccess = cursorBoundaryJWT(subject: "google-oauth2|sqlite-user", expiration: 1)
        let keychainAccess = cursorBoundaryJWT(subject: "google-oauth2|keychain-user")
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: CursorBoundarySQLite(
                    values: [CursorAuthStore.accessTokenKey: sqliteAccess],
                    failingKeys: [CursorAuthStore.refreshTokenKey]
                ),
                keychain: CursorBoundaryKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: keychainAccess
                ]),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            usageClient: CursorUsageClient(http: cursorBoundaryHTTP(accessToken: keychainAccess)),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
    }
}

@MainActor
private func makeCursorBoundaryProvider(
    sqlite: SQLiteAccessing,
    keychain: KeychainAccessing
) -> CursorProvider {
    CursorProvider(
        authStore: CursorAuthStore(sqlite: sqlite, keychain: keychain),
        usageClient: CursorUsageClient(
            http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            )
        )
    )
}

private func cursorBoundaryErrorText(_ snapshot: ProviderSnapshot) -> String? {
    guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
    return text
}

private func cursorBoundaryHTTP(accessToken: String) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        let url = request.url.absoluteString
        if url.contains("GetCurrentPeriodUsage") {
            guard request.headers["Authorization"] == "Bearer \(accessToken)" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"enabled":true,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8)
            )
        }
        if url.contains("GetPlanInfo") {
            guard request.headers["Authorization"] == "Bearer \(accessToken)" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8)
            )
        }
        if url.contains("GetCreditGrantsBalance") {
            guard request.headers["Authorization"] == "Bearer \(accessToken)" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"hasCreditGrants":false}"#.utf8)
            )
        }
        if url.contains("/api/auth/stripe") {
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"customerBalance":"0"}"#.utf8)
            )
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

private func cursorBoundaryJWT(subject: String, expiration: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(subject)","exp":\#(expiration)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "header.\(encoded).signature"
}

private final class CursorBoundarySQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    var failingKeys: Set<String>
    var queriedKeys: [String] = []
    let failAllQueries: Bool

    init(
        values: [String: String] = [:],
        failingKeys: Set<String> = [],
        failAllQueries: Bool = false
    ) {
        self.values = values
        self.failingKeys = failingKeys
        self.failAllQueries = failAllQueries
    }

    func queryValue(path: String, sql: String) throws -> String? {
        guard let key = [
            CursorAuthStore.accessTokenKey,
            CursorAuthStore.refreshTokenKey,
            CursorAuthStore.membershipTypeKey
        ].first(where: { sql.contains($0) }) else {
            return nil
        }
        queriedKeys.append(key)
        if failAllQueries || failingKeys.contains(key) {
            throw CursorBoundaryTestError.unreadable
        }
        return values[key]
    }

    func execute(path: String, sql: String) throws {}
}

private final class CursorBoundaryKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String]
    var failingServices: Set<String>
    var readServices: [String] = []
    let failAllReads: Bool

    init(
        values: [String: String] = [:],
        failingServices: Set<String> = [],
        failAllReads: Bool = false
    ) {
        self.values = values
        self.failingServices = failingServices
        self.failAllReads = failAllReads
    }

    func readGenericPassword(service: String) throws -> String? {
        readServices.append(service)
        if failAllReads || failingServices.contains(service) {
            throw CursorBoundaryTestError.unreadable
        }
        return values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        values[service] = value
    }
}

private enum CursorBoundaryTestError: Error {
    case unreadable
}
