import XCTest
@testable import OpenUsage

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
}

final class CursorUsageMapperTests: XCTestCase {
    func testMapsCreditsUsageBreakdownAndOnDemand() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 1_000
                ]
            ],
            planName: "pro plan",
            creditGrants: [
                "hasCreditGrants": true,
                "totalCents": "1000000",
                "usedCents": "264729"
            ],
            stripeBalanceCents: 991_544
        )

        XCTAssertEqual(mapped.plan, "Pro Plan")
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "Credits")), 17268.15, accuracy: 0.001)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(mapped.lines, "Auto usage")?.used, 12.5)
        XCTAssertEqual(progress(mapped.lines, "API usage")?.used, 7.5)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 40)
    }

    func testBoundedOnDemandDoesNotLetZeroSpendMaskPositiveUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 20
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 4_500,
                    "individualUsed": 0,
                    "totalSpend": 1_200
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 12)
    }

    func testMapsSpendOnlyOnDemandAsUnboundedUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_781_438_541_000,
                "billingCycleEnd": 1_784_030_541_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 26.346,
                    "totalSpend": 52_692
                ],
                "spendLimitUsage": [
                    "individualUsed": 16_474,
                    "limitType": "user",
                    "totalSpend": 16_474
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 790_964
        )

        XCTAssertNil(progress(mapped.lines, "On-demand"))
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "On-demand")), 164.74, accuracy: 0.001)
    }

    func testMapsRequestBasedFallback() throws {
        let mapped = try CursorUsageMapper.mapRequestBasedUsage(
            [
                "gpt-4": [
                    "numRequests": 39,
                    "maxRequestUsage": 500
                ],
                "startOfMonth": "2026-02-09T17:36:37.000Z"
            ],
            planName: "Team",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Team")
        XCTAssertEqual(progress(mapped.lines, "Requests")?.used, 39)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.limit, 500)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.periodDurationMs, CursorUsageMapper.billingPeriodMs)
    }

    func testTeamAccountEmitsDollarTotalUsageAndNoOrphanedBonusSpendLine() throws {
        // Team accounts report Total usage as a dollar meter and may carry a `bonusSpend` field. No
        // widget descriptor matches a "Bonus spend" label, so emitting one produced a line that could
        // never render. Regression: the mapper must not emit that orphaned line even when bonusSpend > 0.
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalSpend": 10_000,
                    "bonusSpend": 2_500
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(mapped.plan, "Team")
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 100, accuracy: 0.001)    // $100.00 spent (totalSpend, cents → dollars)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)   // of a $400.00 limit
        XCTAssertFalse(mapped.lines.contains { $0.label == "Bonus spend" })
    }
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

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
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

// RoutingHTTPClient lives in TestSupport.swift (shared, records requests).
