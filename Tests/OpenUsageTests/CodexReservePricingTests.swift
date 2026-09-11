import XCTest
@testable import OpenUsage

final class CodexReservePricingTests: XCTestCase {
    func testReserveKeepsItsSlugAndUsesLunaRates() throws {
        // Exercise parsing and bundled pricing together, including cached input and Codex tiers.
        for (input, expectedBaseCost) in [(100_000, 0.0248), (300_000, 0.1236)] {
            for tier in ["default", "priority"] {
                let lines = [
                    CodexLogFixture.turnContext(timestamp: "2026-09-07T08:00:00Z", model: "gpt-reserve"),
                    CodexLogFixture.threadSettingsApplied(
                        timestamp: "2026-09-07T08:00:01Z", serviceTier: tier
                    ),
                    CodexLogFixture.tokenCount(
                        timestamp: "2026-09-07T08:01:00Z",
                        last: CodexLogFixture.usage(input: input, cached: 40_000, output: 10_000)
                    )
                ].joined(separator: "\n")
                let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))
                let event = try XCTUnwrap(events.first)
                XCTAssertEqual(events.count, 1)
                XCTAssertEqual(event.model, "gpt-reserve")
                XCTAssertEqual(event.pricingModel, "gpt-5.6-luna")

                let scan = CodexLogUsageScanner.aggregate(
                    events: events, since: .distantPast, pricing: TestPricing.bundled
                )
                let expectedCost = expectedBaseCost * (tier == "priority" ? 2 : 1)
                XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001)
                XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
                XCTAssertEqual(models.count, 1)
                XCTAssertEqual(models.first?.model, "gpt-reserve")
                XCTAssertEqual(models.first?.totalTokens, input + 10_000)
                XCTAssertEqual(try XCTUnwrap(models.first?.costUSD), expectedCost, accuracy: 0.000_001)
            }
        }
    }
}
