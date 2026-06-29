import XCTest
@testable import OpenUsage

final class DevinAuthStoreTests: XCTestCase {
    func testParsesCredentialsTomlAndCleansServerURL() {
        let store = DevinAuthStore(
            files: FakeFiles([
                DevinAuthStore.credentialsPath: """
                windsurf_api_key = "devin-session-token$cli"
                api_server_url = "https://server.codeium.test/"
                """
            ]),
            sqlite: FakeSQLite()
        )

        let auth = store.loadCredentialsFile()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$cli")
        XCTAssertEqual(auth?.apiServerUrl, "https://server.codeium.test")
        XCTAssertEqual(auth?.source, .credentialsFile)
    }

    func testIgnoresPlaintextServerURL() {
        let store = DevinAuthStore(
            files: FakeFiles([
                DevinAuthStore.credentialsPath: """
                windsurf_api_key = "devin-session-token$cli"
                api_server_url = "http://server.codeium.test"
                """
            ]),
            sqlite: FakeSQLite()
        )

        let auth = store.loadCredentialsFile()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$cli")
        XCTAssertNil(auth?.apiServerUrl)
    }

    func testReadsAppAuthFromSQLiteState() {
        let sqlite = FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
        let store = DevinAuthStore(files: FakeFiles(), sqlite: sqlite)

        let auth = store.loadAppAuth()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$app")
        XCTAssertEqual(auth?.source, .appState)
        XCTAssertEqual(sqlite.lastPath, DevinAuthStore.stateDBPath)
        XCTAssertEqual(sqlite.lastSQL?.contains("windsurfAuthStatus"), true)
    }
}

final class DevinUsageMapperTests: XCTestCase {
    func testMapsQuotaLinesAndExtraUsageBalance() throws {
        let mapped = try DevinUsageMapper.mapUserStatus(makeUserStatus())

        XCTAssertEqual(mapped.plan, "Max")
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.periodDurationMs, DevinUsageMapper.dayPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 60)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.periodDurationMs, DevinUsageMapper.weekPeriodMs)
        XCTAssertEqual(try XCTUnwrap(dollars(mapped.lines, "Extra usage balance")), 964.22, accuracy: 0.0001)
        XCTAssertNotNil(progress(mapped.lines, "Weekly quota")?.resetsAt)
    }

    func testZeroOverageBalanceReadsZeroDollarsNotNoData() throws {
        var userStatus = makeUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        planStatus["overageBalanceMicros"] = "0"
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        // A present balance of zero is a real, measured value → 0, not "No data" (that's reserved
        // for the field being absent entirely).
        XCTAssertEqual(dollars(mapped.lines, "Extra usage balance"), 0)
    }

    func testUsesHiddenDailyQuotaAsWeeklyUsageWhenWeeklyIsAbsent() throws {
        var userStatus = makeUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        var planInfo = planStatus["planInfo"] as! [String: Any]
        planInfo["hideDailyQuota"] = true
        planStatus["planInfo"] = planInfo
        planStatus["dailyQuotaRemainingPercent"] = 30
        planStatus.removeValue(forKey: "weeklyQuotaRemainingPercent")
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        XCTAssertNil(progress(mapped.lines, "Daily quota"))
        // The hidden daily quota fills the missing Weekly row and is still flipped from "remaining"
        // to "used": 30% remaining -> 70% used (not passed through raw as 30).
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 70)
        XCTAssertEqual(try XCTUnwrap(dollars(mapped.lines, "Extra usage balance")), 964.22, accuracy: 0.0001)
    }

    func testThrowsQuotaUnavailableWhenNoDisplayableFieldsExist() {
        let userStatus: [String: Any] = [
            "planStatus": [
                "planInfo": ["planName": "Max"]
            ]
        ]

        XCTAssertThrowsError(try DevinUsageMapper.mapUserStatus(userStatus)) { error in
            XCTAssertEqual(error as? DevinUsageError, .quotaUnavailable)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    /// The first dollar value's raw number on a `.values` line (the shape extra-usage balance now uses).
    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class DevinProviderTests: XCTestCase {
    func testRefreshUsesCredentialsFileBeforeAppState() async throws {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try makeUserStatusBody())
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(httpClient.requests.first?.url.absoluteString, "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        let body = try requestBody(httpClient.requests.first)
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["apiKey"] as? String, "devin-session-token$cli")
        XCTAssertEqual(metadata?["ideName"] as? String, "devin")
        XCTAssertEqual(metadata?["extensionVersion"] as? String, DevinUsageClient.cloudCompatVersion)
    }

    func testRefreshFallsBackToAppStateAfterExpiredCredentials() async throws {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: try makeUserStatusBody(planName: "Teams"))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Teams")
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [
            "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        ])
    }

    func testRefreshReturnsLoginHintWithoutAuth() async {
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite()),
            usageClient: DevinUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.notLoggedIn.localizedDescription)
        // The final fallback must carry a real telemetry category (regression: it once used the
        // message-only factory, leaving errorCategory nil so failures bucketed as `other`).
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}

private func makeUserStatus(planName: String = "Max") -> [String: Any] {
    [
        "planStatus": [
            "planInfo": [
                "planName": planName,
                "billingStrategy": "BILLING_STRATEGY_QUOTA"
            ],
            "dailyQuotaRemainingPercent": 100,
            "weeklyQuotaRemainingPercent": 40,
            "overageBalanceMicros": "964220000",
            "dailyQuotaResetAtUnix": "1774080000",
            "weeklyQuotaResetAtUnix": "1774166400"
        ]
    ]
}

private func makeUserStatusBody(planName: String = "Max") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["userStatus": makeUserStatus(planName: planName)])
}

private func requestBody(_ request: HTTPRequest?) throws -> [String: Any] {
    let data = try XCTUnwrap(request?.body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var value: String?
    var lastPath: String?
    var lastSQL: String?

    init(value: String? = nil) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lastPath = path
        lastSQL = sql
        return value
    }

    func execute(path: String, sql: String) throws {}
}

private final class QueueHTTPClient: HTTPClient, @unchecked Sendable {
    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}
