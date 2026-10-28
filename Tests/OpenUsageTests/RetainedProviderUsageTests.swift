import XCTest
@testable import OpenUsage

final class RetainedProviderUsageTests: XCTestCase {
    func testCopilotMapperUsesProviderReportedRemainingCredits() throws {
        let mapped = try CopilotUsageMapper.map(body: [
            "copilot_plan": "pro",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 100, "remaining": 75]
            ]
        ])

        XCTAssertEqual(mapped.plan, "Pro")
        guard case .progress(_, let used, let limit, _, _, _) =
            mapped.lines.first(where: { $0.label == "Credits" })
        else { return XCTFail("expected Credits meter") }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(limit, 100)
    }

    func testGrokMapperMapsWeeklyPoolAndPayAsYouGoCap() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-03T04:01:09Z","end":"2026-07-10T04:01:09Z"},"creditUsagePercent":37.5,"onDemandCap":{"val":2500}}}"#.utf8)
        )

        let mapped = try GrokUsageMapper.mapCreditsConfig(response)

        XCTAssertTrue(mapped.lines.contains { $0.label == "Weekly limit" })
        guard case .badge(_, let text) = mapped.lines.first(where: { $0.label == "Pay as you go" })
        else { return XCTFail("expected Pay as you go badge") }
        XCTAssertEqual(text, "2500 cap")
    }

    func testOpenRouterMapperKeepsProviderReturnedBalance() {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_usage": 2.5, "total_credits": 10])

        XCTAssertEqual(lines.map(\.label), ["Balance"])
        guard case .values(_, let values, _) = lines.first
        else { return XCTFail("expected Balance value") }
        XCTAssertEqual(values.first?.number, 7.5)
    }

    func testOllamaMapperKeepsProviderReturnedMonthlyDollarLimit() throws {
        let lines = try OllamaUsageMapper.balanceLines(Data(#"""
        {"included":{"allowance_usd":100,"balance_usd":72.5,
          "period":{"from":"2026-06-01T00:00:00Z","until":"2026-07-01T00:00:00Z"}}}
        """#.utf8))

        guard case .progress(_, let used, let limit, let format, _, _) =
            lines.first(where: { $0.label == "Monthly" })
        else { return XCTFail("expected Monthly meter") }
        XCTAssertEqual(used, 27.5)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .dollars)
    }

    func testOllamaBalanceClientUsesBearerAPIKey() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))

        _ = try await OllamaUsageClient(http: http).fetchBalance(apiKey: "app-owned-key")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://ollama.com/api/balance"))
        XCTAssertEqual(request.headers["Authorization"], "Bearer app-owned-key")
    }
}
