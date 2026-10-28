import XCTest
@testable import OpenUsage

final class CursorUsageSummaryMapperTests: XCTestCase {
    func testMapsProviderReturnedOnDemandDollars() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "membershipType": "enterprise",
                "individualUsage": [
                    "plan": ["enabled": true, "limit": 0, "totalPercentUsed": 6.25],
                    "onDemand": ["enabled": true, "used": 12_345, "limit": 200_000]
                ]
            ],
            requestUsage: nil,
            planName: "Enterprise",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Enterprise")
        guard case .progress(_, let used, let limit, let format, _, _) =
            mapped.lines.first(where: { $0.label == "On-demand" })
        else { return XCTFail("expected On-demand meter") }
        XCTAssertEqual(used, 123.45)
        XCTAssertEqual(limit, 2_000)
        XCTAssertEqual(format, .dollars)
    }

    func testRejectsResponseWithoutUsableMetrics() {
        XCTAssertThrowsError(try CursorUsageSummaryMapper.map(
            summary: ["individualUsage": ["plan": ["limit": 0]]],
            requestUsage: nil,
            planName: nil,
            unavailableMessage: "unavailable"
        ))
    }
}
