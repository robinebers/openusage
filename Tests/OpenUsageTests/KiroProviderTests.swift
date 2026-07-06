import XCTest
@testable import OpenUsage

// MARK: - Mapper Tests

final class KiroProviderTests: XCTestCase {
    // MARK: Success mapping

    func testMapCreditsUsed() throws {
        let body: [String: Any] = [
            "subscriptionInfo": [
                "subscriptionTitle": "KIRO FREE",
                "type": "Q_DEVELOPER_STANDALONE_FREE",
                "upgradeCapability": "UPGRADE_CAPABLE",
                "overageCapability": "OVERAGE_INCAPABLE"
            ],
            "usageBreakdownList": [
                [
                    "currentUsage": 6,
                    "currentUsageWithPrecision": 6.82,
                    "usageLimit": 50,
                    "usageLimitWithPrecision": 50.0,
                    "displayName": "Credit",
                    "displayNamePlural": "Credits",
                    "nextDateReset": 1785542400,
                    "overageRate": 0.04,
                    "currency": "USD",
                    "currentOverages": 0,
                    "overageCharges": 0.0,
                    "resourceType": "CREDIT"
                ]
            ],
            "daysUntilReset": 0
        ]

        let mapped = try KiroUsageMapper.mapUsageLimits(body)

        XCTAssertEqual(mapped.plan, "Kiro Free")
        XCTAssertEqual(mapped.lines.count, 1)

        let credits = mapped.lines[0]
        XCTAssertEqual(credits.label, "Credits")
        if case .progress(_, let used, let limit, _, _, _, _) = credits {
            XCTAssertEqual(used, 6, accuracy: 0.01)
            XCTAssertEqual(limit, 50, accuracy: 0.01)
        } else {
            XCTFail("Expected .progress for credits line, got: \(credits)")
        }
    }

    func testMapPlanNameFormatting() throws {
        let cases: [(String, String)] = [
            ("KIRO FREE", "Kiro Free"),
            ("KIRO PRO", "Kiro Pro"),
            ("KIRO POWER", "Kiro Power"),
            ("Q_DEVELOPER_STANDALONE_FREE", "Q Developer Standalone Free")
        ]
        for (input, expected) in cases {
            let body: [String: Any] = [
                "subscriptionInfo": ["subscriptionTitle": input],
                "usageBreakdownList": [[
                    "currentUsage": 1,
                    "usageLimit": 50,
                    "displayNamePlural": "Credits",
                    "nextDateReset": 1785542400
                ]]
            ]
            let mapped = try KiroUsageMapper.mapUsageLimits(body)
            XCTAssertEqual(mapped.plan, expected, "Plan title '\(input)' should format as '\(expected)'")
        }
    }

    func testMapResetsAt() throws {
        let nextReset: Double = 1785542400
        let body: [String: Any] = [
            "subscriptionInfo": ["subscriptionTitle": "KIRO FREE"],
            "usageBreakdownList": [[
                "currentUsage": 6,
                "usageLimit": 50,
                "displayNamePlural": "Credits",
                "nextDateReset": nextReset
            ]]
        ]

        let mapped = try KiroUsageMapper.mapUsageLimits(body)
        XCTAssertEqual(mapped.lines.count, 1)

        if case .progress(_, _, _, _, let resetsAt, _, _) = mapped.lines[0] {
            let expectedDate = Date(timeIntervalSince1970: nextReset)
            XCTAssertEqual(resetsAt, expectedDate)
        } else {
            XCTFail("Expected .progress")
        }
    }

    func testMapOverageCharges() throws {
        let body: [String: Any] = [
            "subscriptionInfo": ["subscriptionTitle": "KIRO PRO"],
            "usageBreakdownList": [[
                "currentUsage": 55,
                "usageLimit": 50,
                "displayNamePlural": "Credits",
                "nextDateReset": 1785542400,
                "overageCharges": 2.0,
                "currency": "USD"
            ]]
        ]

        let mapped = try KiroUsageMapper.mapUsageLimits(body)
        // Should have credits + overage charges
        XCTAssertEqual(mapped.lines.count, 2)
        let overageLine = mapped.lines.first { $0.label == "Overage Charges" }
        XCTAssertNotNil(overageLine)
        if let overageLine,
           case .values(_, let values, _, _, _, _) = overageLine {
            let number = try XCTUnwrap(values.first?.number)
            XCTAssertEqual(number, 2.0, accuracy: 0.01)
            XCTAssertEqual(values.first?.kind, .dollars)
        } else {
            XCTFail("Expected .values for overage charges")
        }

        // The credits line must keep reporting the true (over-limit) usage, not clamp to the
        // plan limit — otherwise a user in overage would see "50 of 50" and never know they'd
        // gone over, despite the separate Overage Charges row.
        let creditsLine = mapped.lines.first { $0.label == "Credits" }
        if case .progress(_, let used, let limit, _, _, _, _) = creditsLine {
            XCTAssertEqual(used, 55, accuracy: 0.01)
            XCTAssertEqual(limit, 50, accuracy: 0.01)
        } else {
            XCTFail("Expected .progress for credits line")
        }
    }

    func testMapNoOverageChargesWhenZero() throws {
        let body: [String: Any] = [
            "subscriptionInfo": ["subscriptionTitle": "KIRO FREE"],
            "usageBreakdownList": [[
                "currentUsage": 6,
                "usageLimit": 50,
                "displayNamePlural": "Credits",
                "nextDateReset": 1785542400,
                "overageCharges": 0.0
            ]]
        ]

        let mapped = try KiroUsageMapper.mapUsageLimits(body)
        XCTAssertEqual(mapped.lines.count, 1, "Zero overage charges should not produce an overage line")
    }

    func testMapEmptyBreakdownThrows() {
        let body: [String: Any] = [
            "subscriptionInfo": ["subscriptionTitle": "KIRO FREE"],
            "usageBreakdownList": [] as [[String: Any]]
        ]
        XCTAssertThrowsError(try KiroUsageMapper.mapUsageLimits(body)) { error in
            XCTAssertTrue(error is KiroUsageError)
        }
    }

    func testMapBreakdownMissingLimitSkipped() throws {
        // Breakdown entry without usageLimit should be skipped; if all skipped → throw
        let body: [String: Any] = [
            "subscriptionInfo": ["subscriptionTitle": "KIRO FREE"],
            "usageBreakdownList": [[
                "currentUsage": 6,
                // usageLimit missing
                "displayNamePlural": "Credits",
                "nextDateReset": 1785542400
            ]]
        ]
        XCTAssertThrowsError(try KiroUsageMapper.mapUsageLimits(body))
    }

    func testMapInvalidJsonThrows() throws {
        // Simulating a non-200 body: wrap a bad response
        let badBody = Data("not json".utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: badBody)
        XCTAssertThrowsError(try KiroUsageMapper.mapUsageLimitsResponse(response))
    }
}

// MARK: - Auth Store Tests

final class KiroAuthStoreTests: XCTestCase {
    func testLoadAuthReturnsNilWhenNoToken() {
        let store = KiroAuthStore(sqlite: StubSQLite(value: nil))
        XCTAssertNil(store.loadAuth())
    }

    func testLoadAuthParsesAccessToken() {
        let json = """
        {"access_token":"test-token-123","expires_at":"2099-01-01T00:00:00Z","refresh_token":"rtoken","provider":"github","profile_arn":"arn:aws:codewhisperer:us-east-1:123:profile/XYZ"}
        """
        let store = KiroAuthStore(sqlite: StubSQLite(authKV: json, state: nil))
        let auth = store.loadAuth()
        XCTAssertNotNil(auth)
        XCTAssertEqual(auth?.accessToken, "test-token-123")
        XCTAssertEqual(auth?.refreshToken, "rtoken")
        // Profile ARN comes from state table, not the auth token
        XCTAssertNil(auth?.profileArn)
    }

    func testLoadAuthWithProfileArn() {
        let json = """
        {"access_token":"test-token","expires_at":"2099-01-01T00:00:00Z","provider":"github","profile_arn":"arn:..."}
        """
        let profileJSON = """
        {"arn":"arn:aws:codewhisperer:us-east-1:123:profile/ABC","profile_name":"Social_Default_Profile"}
        """
        let store = KiroAuthStore(sqlite: StubSQLite(authKV: json, state: profileJSON))
        let auth = store.loadAuth()
        XCTAssertEqual(auth?.profileArn, "arn:aws:codewhisperer:us-east-1:123:profile/ABC")
    }

    func testLoadAuthReturnsNilForMalformedJSON() {
        let store = KiroAuthStore(sqlite: StubSQLite(authKV: "not-json", state: nil))
        XCTAssertNil(store.loadAuth())
    }

    func testLoadAuthReturnsNilForEmptyAccessToken() {
        let json = """
        {"access_token":"   ","expires_at":"2099-01-01T00:00:00Z"}
        """
        let store = KiroAuthStore(sqlite: StubSQLite(authKV: json, state: nil))
        XCTAssertNil(store.loadAuth())
    }
}

// MARK: - Provider Runtime Tests

@MainActor
final class KiroProviderRuntimeTests: XCTestCase {
    func testCreditsDescriptorMatchesMappedLineLabel() throws {
        let provider = KiroProvider()
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "kiro.credits" })
        XCTAssertEqual(descriptor.metricLabel, "Credits")
    }

    func testHasLocalCredentialsReturnsFalseWhenNoToken() async {
        let store = KiroAuthStore(sqlite: StubSQLite(value: nil))
        let provider = KiroProvider(authStore: store, usageClient: KiroUsageClient())
        let result = await provider.hasLocalCredentials()
        XCTAssertFalse(result)
    }

    func testRefreshReturnsErrorWhenNotLoggedIn() async {
        let store = KiroAuthStore(sqlite: StubSQLite(value: nil))
        let provider = KiroProvider(authStore: store)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }
}

// MARK: - Stubs

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    private let authKV: String?
    private let state: String?

    init(value: String?) {
        self.authKV = value
        self.state = nil
    }

    init(authKV: String?, state: String?) {
        self.authKV = authKV
        self.state = state
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if sql.contains("auth_kv") {
            return authKV
        } else if sql.contains("state") {
            return state
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
