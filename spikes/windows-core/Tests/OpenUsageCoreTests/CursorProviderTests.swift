import XCTest
@testable import OpenUsageCore
#if os(Windows)
import Win32Shim
#endif

final class WindowsCredentialVaultAccessorTests: XCTestCase {
    func testReadMissingServiceReturnsNil() throws {
        let accessor = WindowsCredentialVaultAccessor()
        XCTAssertNil(try accessor.readGenericPassword(service: "openusage-test-missing-\(UUID().uuidString)"))
    }

    #if os(Windows)
    func testReadGeminiAntigravityWhenPresent() throws {
        // Integration: skipped when the Antigravity credential entry is absent on this machine.
        let accessor = WindowsCredentialVaultAccessor()
        let value = try accessor.readGenericPassword(service: "gemini", account: "antigravity")
        try XCTSkipIf(value == nil, "gemini:antigravity not in Credential Manager on this machine")
        XCTAssertGreaterThan(value?.count ?? 0, 0)
    }
    #endif
}

final class WinSQLiteAccessorTests: XCTestCase {
    #if os(Windows)
    func testReadsFixtureVscdb() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-vscdb-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("state.vscdb").path

        let token = "fixture-access-token"
        let rc = ou_sqlite_write_fixture(dbPath, CursorAuthStore.accessTokenKey, token)
        XCTAssertEqual(rc, OU_SQLITE_OK)

        let accessor = WinSQLiteAccessor()
        let sql = "SELECT value FROM ItemTable WHERE key = '\(CursorAuthStore.accessTokenKey)' LIMIT 1;"
        let value = try accessor.queryValue(path: dbPath, sql: sql)
        XCTAssertEqual(value, token)
    }

    func testExecuteIsReadOnly() {
        let accessor = WinSQLiteAccessor()
        XCTAssertThrowsError(try accessor.execute(path: "/tmp/x", sql: "DELETE FROM ItemTable;")) { error in
            XCTAssertEqual(error as? SQLiteError, .readOnly)
        }
    }
    #endif
}

final class CursorAuthStoreTests: XCTestCase {
    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() {
        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.refreshTokenKey: "sqlite-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken,
            CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
        XCTAssertEqual(state?.refreshToken, "keychain-refresh")
    }

    func testPersistsSQLiteAccessToken() throws {
        let sqlite = FakeSQLite()
        let store = CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain())

        try store.saveAccessToken("fresh-token", source: .sqlite)

        XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], "fresh-token")
    }

    #if os(Windows)
    func testWindowsStateDBPathUsesAppData() {
        let path = CursorAuthStore.stateDBPath
        XCTAssertTrue(path.contains("Cursor"))
        XCTAssertTrue(path.contains("globalStorage"))
        XCTAssertTrue(path.hasSuffix("state.vscdb"))
        XCTAssertFalse(path.hasPrefix("~"))
    }
    #endif
}

@MainActor
final class CursorProviderTests: XCTestCase {
    func testRefreshFetchesLiveCursorUsage() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 40000,
                    "remaining": 32000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                  },
                  "spendLimitUsage": {
                    "individualLimit": 5000,
                    "individualRemaining": 1000
                  }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            if url.contains("/api/auth/stripe") {
                XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":"-50000"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertEqual(dollarValue(snapshot.lines, "Credits") ?? -1, 500)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(snapshot.lines, "Auto usage")?.used, 12.5)
        XCTAssertEqual(progress(snapshot.lines, "API usage")?.used, 7.5)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 40)
    }
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func dollarValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first { $0.kind == .dollars }?.number
}

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    var writtenValues: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }

    func execute(path: String, sql: String) throws {
        guard let key = sqlValue(after: "(key, value) VALUES ('", in: sql),
              let value = sqlValue(after: "', '", in: sql)
        else {
            return
        }
        writtenValues[key] = value
    }

    private func sqlValue(after marker: String, in sql: String) -> String? {
        guard let start = sql.range(of: marker)?.upperBound,
              let end = sql[start...].range(of: "'")?.lowerBound
        else {
            return nil
        }
        return String(sql[start..<end]).replacingOccurrences(of: "''", with: "'")
    }
}
