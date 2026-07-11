import XCTest
@testable import OpenUsage

final class KiroUsageMapperTests: XCTestCase {

    func testMapsCreditsWithEpochSecondsResetDate() throws {
        let augustFirst2026Seconds = 1_776_192_000.0
        let body = try makeUsageBody(
            subscriptionTitle: "KIRO PRO",
            usageBreakdownList: [
                ["type": "CREDIT", "currentUsage": 200, "usageLimit": 1000, "resetDate": augustFirst2026Seconds]
            ]
        )

        let mapped = try KiroUsageMapper.map(body)

        let credits = progress(mapped.lines, "Credits")
        XCTAssertEqual(credits?.used, 200)
        XCTAssertNotNil(credits?.resetsAt)
        if let resetsAt = credits?.resetsAt {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: resetsAt)
            XCTAssertEqual(components.year, 2026)
            XCTAssertEqual(components.month, 8)
            XCTAssertEqual(components.day, 1)
        }
    }

    func testMapsCreditsAndPlan() throws {
        let body = try makeUsageBody(
            subscriptionTitle: "KIRO PRO",
            usageBreakdownList: [
                ["type": "CREDIT", "currentUsage": 200, "usageLimit": 1000, "resetDate": "2026-05-01T00:00:00.000Z"]
            ]
        )

        let mapped = try KiroUsageMapper.map(body)

        XCTAssertEqual(mapped.plan, "KIRO PRO")
        let credits = progress(mapped.lines, "Credits")
        XCTAssertEqual(credits?.used, 200)
        XCTAssertEqual(credits?.limit, 1000)
        XCTAssertNotNil(credits?.resetsAt)
    }

    func testIgnoresNonCreditBreakdownEntries() throws {
        let body = try makeUsageBody(
            usageBreakdownList: [
                ["type": "CREDIT", "currentUsage": 200, "usageLimit": 1000, "resetDate": "2026-05-01T00:00:00.000Z"],
                ["type": "CHAT", "currentUsage": 50, "usageLimit": 500, "resetDate": "2026-05-01T00:00:00.000Z"]
            ]
        )

        let mapped = try KiroUsageMapper.map(body)

        let creditLines = mapped.lines.filter { $0.label == "Credits" }
        XCTAssertEqual(creditLines.count, 1)
        let credits = progress(mapped.lines, "Credits")
        XCTAssertEqual(credits?.used, 200)
        XCTAssertEqual(credits?.limit, 1000)
    }

    func testMapsBonusCredits() throws {
        let body = try makeUsageBody(
            usageBreakdownList: [
                ["type": "CREDIT", "currentUsage": 10, "usageLimit": 50, "resetDate": "2026-05-01T00:00:00.000Z"]
            ],
            freeTrialUsage: [
                "currentUsage": 106.11,
                "usageLimit": 500,
                "expiryDate": "2026-05-03T15:09:55.196Z"
            ]
        )

        let mapped = try KiroUsageMapper.map(body)

        let bonus = progress(mapped.lines, "Bonus Credits")
        XCTAssertEqual(try XCTUnwrap(bonus?.used), 106.11, accuracy: 0.01)
        XCTAssertEqual(bonus?.limit, 500)
    }

    func testMapsOverageBadge() throws {
        let body = try makeUsageBody(
            usageBreakdownList: [
                ["type": "CREDIT", "currentUsage": 10, "usageLimit": 50, "resetDate": "2026-05-01T00:00:00.000Z"]
            ],
            overageStatus: "Enabled"
        )

        let mapped = try KiroUsageMapper.map(body)

        let badge = mapped.lines.first { $0.label == "Overages" }
        if case .badge(_, let text, _, _) = badge {
            XCTAssertEqual(text, "Enabled")
        } else {
            XCTFail("Expected Overages badge")
        }
    }

    func testThrowsQuotaUnavailableWhenNoBreakdown() {
        let body = Data("{}".utf8)

        XCTAssertThrowsError(try KiroUsageMapper.map(body)) { error in
            XCTAssertEqual(error as? KiroUsageError, .quotaUnavailable)
        }
    }

    func testThrowsInvalidResponseForNonJSON() {
        let body = Data("not json".utf8)

        XCTAssertThrowsError(try KiroUsageMapper.map(body)) { error in
            XCTAssertEqual(error as? KiroUsageError, .invalidResponse)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt)
    }

    private func makeUsageBody(
        subscriptionTitle: String? = nil,
        usageBreakdownList: [[String: Any]] = [],
        freeTrialUsage: [String: Any]? = nil,
        overageStatus: String? = nil
    ) throws -> Data {
        var root: [String: Any] = [:]
        if let subscriptionTitle {
            root["subscriptionInfo"] = ["subscriptionTitle": subscriptionTitle]
        }
        root["usageBreakdownList"] = usageBreakdownList
        if let freeTrialUsage {
            root["freeTrialUsage"] = freeTrialUsage
        }
        if let overageStatus {
            root["overageConfiguration"] = ["overageStatus": overageStatus]
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

@MainActor
final class KiroProviderTests: XCTestCase {
    func testRefreshReturnsLoginHintWithoutAuth() async {
        let provider = KiroProvider(
            authStore: KiroAuthStore(files: FakeFiles(), sqlite: FakeSQLite()),
            usageClient: KiroUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), KiroAuthError.notLoggedIn.localizedDescription)
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshFetchesUsageWithTokenFile() async throws {
        let tokenJSON = try JSONSerialization.data(withJSONObject: [
            "accessToken": "kiro-access-token",
            "refreshToken": "kiro-refresh-token",
            "profileArn": "arn:aws:codewhisperer:us-east-1:123:profile/ABC",
            "region": "us-east-1"
        ])
        let usageBody = try JSONSerialization.data(withJSONObject: [
            "subscriptionInfo": ["subscriptionTitle": "KIRO FREE"],
            "usageBreakdownList": [
                ["type": "CREDIT", "currentUsage": 10, "usageLimit": 50, "resetDate": "2026-05-01T00:00:00.000Z"]
            ]
        ])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: usageBody)
        ])
        let provider = KiroProvider(
            authStore: KiroAuthStore(
                files: FakeFiles([
                    KiroAuthStore.tokenFilePath: String(decoding: tokenJSON, as: UTF8.self)
                ]),
                sqlite: FakeSQLite()
            ),
            usageClient: KiroUsageClient(http: httpClient),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "KIRO FREE")
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertTrue(httpClient.requests.first?.url.absoluteString.contains("getUsageLimits") == true)
    }

    func testRefreshRetriesAfterTokenRefresh() async throws {
        let tokenJSON = try JSONSerialization.data(withJSONObject: [
            "accessToken": "expired-token",
            "refreshToken": "kiro-refresh-token",
            "profileArn": "arn:aws:codewhisperer:us-east-1:123:profile/ABC",
            "region": "us-east-1"
        ])
        let refreshedTokenJSON = try JSONSerialization.data(withJSONObject: [
            "accessToken": "fresh-token",
            "refreshToken": "new-refresh-token",
            "expiresIn": 28800
        ])
        let usageBody = try JSONSerialization.data(withJSONObject: [
            "subscriptionInfo": ["subscriptionTitle": "KIRO PRO"],
            "usageBreakdownList": [
                ["type": "CREDIT", "currentUsage": 200, "usageLimit": 1000, "resetDate": "2026-05-01T00:00:00.000Z"]
            ]
        ])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: refreshedTokenJSON),
            HTTPResponse(statusCode: 200, headers: [:], body: usageBody),
        ])
        let provider = KiroProvider(
            authStore: KiroAuthStore(
                files: FakeFiles([
                    KiroAuthStore.tokenFilePath: String(decoding: tokenJSON, as: UTF8.self)
                ]),
                sqlite: FakeSQLite()
            ),
            usageClient: KiroUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "KIRO PRO")
        XCTAssertEqual(httpClient.requests.count, 3)
        // First request uses expired token, third uses refreshed token
        XCTAssertEqual(httpClient.requests[0].headers["Authorization"], "Bearer expired-token")
        XCTAssertEqual(httpClient.requests[2].headers["Authorization"], "Bearer fresh-token")
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        value
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
