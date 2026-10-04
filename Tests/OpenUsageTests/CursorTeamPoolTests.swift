import XCTest
@testable import OpenUsage

final class CursorTeamPoolTests: XCTestCase {
    func testReportedStandardSeatUsesStructuredTotalInsteadOfLegacyTwentyDollars() throws {
        let mapped = try map([
            "totalSpend": 1022, "includedSpend": 1022, "remaining": 978, "limit": 2000,
            "autoPercentUsed": 2.6476190476190475, "apiPercentUsed": 11.65, "totalPercentUsed": 4.088
        ])
        assertPercent(mapped, "Total usage", 4.088)
        assertPercent(mapped, "Cursor Models", 2.6476190476190475)
        assertPercent(mapped, "Other Models", 11.65)
    }

    func testPremiumSeatWithoutTotalDoesNotInventDollarOrPercentageTotal() throws {
        let mapped = try map([
            "limit": 2000, "totalSpend": 666,
            "autoPercentUsed": 0.3728571428571429, "apiPercentUsed": 2.025
        ])
        XCTAssertNil(mapped.lines.first { $0.label == "Total usage" })
        assertPercent(mapped, "Cursor Models", 0.3728571428571429)
        assertPercent(mapped, "Other Models", 2.025)
    }

    func testPoolsWithoutLimitDoNotTriggerRequestFallback() throws {
        let usage: [String: Any] = [
            "enabled": true,
            "planUsage": ["autoPercentUsed": 0, "apiPercentUsed": 0],
            "spendLimitUsage": ["limitType": "team"]
        ]
        for name: String? in ["Team", "Enterprise", nil] {
            XCTAssertFalse(CursorUsageMapper.shouldUseRequestBasedFallback(
                usage: usage, planName: name, planInfoUnavailable: name == nil
            ).shouldFallback)
        }
        XCTAssertFalse(CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback)
        let mapped = try CursorUsageMapper.mapUsage(
            usage: usage, planName: nil, creditGrants: nil, stripeBalanceCents: 0
        )
        assertPercent(mapped, "Cursor Models", 0)
        assertPercent(mapped, "Other Models", 0)
    }

    func testLegacyFiveThousandDollarPoolWithZeroPlaceholdersKeepsDollarMeter() throws {
        let mapped = try map([
            "limit": 500_000, "totalSpend": 234_500,
            "autoPercentUsed": 0, "apiPercentUsed": 0, "totalPercentUsed": 0
        ])
        guard case .progress(_, let used, let limit, let format, _, _, _) =
            mapped.lines.first(where: { $0.label == "Total usage" }) else {
            return XCTFail("Missing legacy total")
        }
        XCTAssertEqual(used, 2345)
        XCTAssertEqual(limit, 5000)
        XCTAssertEqual(format, .dollars)
    }

    func testIncompleteOrMalformedPoolsKeepLegacyFallback() throws {
        for pools: [String: Any] in [
            ["autoPercentUsed": 1],
            ["autoPercentUsed": true, "apiPercentUsed": 2],
            ["autoPercentUsed": -1, "apiPercentUsed": 2],
            ["autoPercentUsed": Double.infinity, "apiPercentUsed": 2]
        ] {
            let plan = pools.merging(["limit": 500_000, "totalSpend": 234_500]) { first, _ in first }
            let mapped = try map(plan)
            guard case .progress(_, _, _, let format, _, _, _) =
                mapped.lines.first(where: { $0.label == "Total usage" }) else {
                return XCTFail("Missing legacy total")
            }
            XCTAssertEqual(format, .dollars)
        }
    }

    func testTeamNameAloneRecognizesPoolsAndPreservesExtraUsageAndCredits() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "planUsage": ["limit": 2000, "autoPercentUsed": 0, "apiPercentUsed": 12],
                "spendLimitUsage": ["individualLimit": 5000, "individualRemaining": 4000]
            ],
            planName: " Team ", creditGrants: nil, stripeBalanceCents: 1000
        )
        XCTAssertNil(mapped.lines.first { $0.label == "Total usage" })
        XCTAssertNotNil(mapped.lines.first { $0.label == "On-demand" })
        XCTAssertNotNil(mapped.lines.first { $0.label == "Credits" })
    }

    private func map(_ plan: [String: Any]) throws -> CursorMappedUsage {
        try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true, "planUsage": plan,
                "billingCycleStart": 1_770_000_000_000, "billingCycleEnd": 1_772_592_000_000,
                "spendLimitUsage": ["limitType": "team", "pooledUsed": 0]
            ],
            planName: "Team", creditGrants: nil, stripeBalanceCents: 0
        )
    }

    private func assertPercent(_ mapped: CursorMappedUsage, _ label: String, _ expected: Double,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .progress(_, let used, let limit, let format, _, _, _) =
            mapped.lines.first(where: { $0.label == label }) else {
            return XCTFail("Missing \(label)", file: file, line: line)
        }
        XCTAssertEqual(used, expected, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(limit, 100, file: file, line: line)
        XCTAssertEqual(format, .percent, file: file, line: line)
    }
}
