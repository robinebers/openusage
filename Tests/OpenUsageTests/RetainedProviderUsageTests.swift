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
}
