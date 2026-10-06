import XCTest
@testable import OpenUsage

final class CodexAutoReviewPricingTests: XCTestCase {
    private let autoReview = "codex-auto-review"

    private func parsedEvents(date: String = "2026-10-06", model: String = "codex-auto-review") -> [CodexLogUsageScanner.Event] {
        let lines = [
            CodexLogFixture.turnContext(timestamp: "\(date)T08:00:00Z", model: model),
            CodexLogFixture.tokenCount(
                timestamp: "\(date)T08:01:00Z",
                last: CodexLogFixture.usage(input: 100_000, cached: 40_000, output: 10_000)
            )
        ].joined(separator: "\n")
        return CodexLogUsageScanner.parseFile(Data(lines.utf8))
    }

    func testParsedAutoReviewKeepsItsNameAndTokensAtZeroCostForEveryDate() throws {
        let events = ["2026-03-10", "2026-08-20", "2026-10-06"].flatMap { parsedEvents(date: $0) }
        XCTAssertEqual(events.map(\.model), Array(repeating: autoReview, count: 3))

        for pricing in [TestPricing.bundled, .empty] {
            let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing)
            XCTAssertEqual(scan.series.daily.count, 3)
            XCTAssertEqual(scan.modelUsage?.daily.count, 3)
            for day in scan.series.daily {
                XCTAssertEqual(day.totalTokens, 110_000)
                XCTAssertEqual(try XCTUnwrap(day.costUSD), 0)
                XCTAssertEqual(
                    scan.modelUsage?.daily.first(where: { $0.date == day.date })?.models,
                    [ModelUsageEntry(model: autoReview, totalTokens: 110_000, costUSD: 0)]
                )
            }
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
            XCTAssertNil(scan.fallbackPricingModelsByDay)
        }
    }

    func testSelectedPaidFallbackCannotChargeAutoReviewOrAddWarnings() throws {
        let fallback = "gpt-5.6-sol"
        let paidRates = ModelRates(
            inputPerMillion: 5, outputPerMillion: 30,
            cacheWritePerMillion: 5, cacheReadPerMillion: 0.5
        )
        let pricing = ModelPricing(
            supplement: PricingSupplement(
                pricing: [fallback: paidRates], fallbackModels: ["codex": [fallback]]
            ),
            primary: PricingCatalog(), secondary: PricingCatalog()
        )
        let scan = CodexLogUsageScanner.aggregate(
            events: parsedEvents(), since: .distantPast, pricing: pricing, fallbackModel: fallback
        )

        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000)
        XCTAssertEqual(
            scan.modelUsage?.daily.first?.models,
            [ModelUsageEntry(model: autoReview, totalTokens: 110_000, costUSD: 0)]
        )
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        XCTAssertNil(scan.fallbackPricingModelsByDay)
    }

    func testCachedLunaMappingAndServiceTiersCannotChargeAutoReview() throws {
        var event = try XCTUnwrap(parsedEvents(date: "2026-08-20").first)
        // Persistent caches from older builds can retain the previous paid pricing model.
        event.pricingModel = "gpt-5.6-luna"
        for input in [100_000, 300_000] {
            for (fast, ultrafast) in [(false, false), (true, false), (false, true)] {
                event.input = input
                event.total = input + event.output
                event.isFast = fast
                event.isUltrafast = ultrafast
                for pricing in [TestPricing.bundled, .empty] {
                    let scan = CodexLogUsageScanner.aggregate(
                        events: [event], since: .distantPast, pricing: pricing
                    )
                    XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0)
                    XCTAssertEqual(scan.series.daily.first?.totalTokens, event.total)
                    XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, autoReview)
                    XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.costUSD, 0)
                    XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                    XCTAssertNil(scan.fallbackPricingModelsByDay)
                }
            }
        }
    }

    func testFreeAutoReviewRemainsSeparateFromPaidLunaAndReserve() throws {
        let events = [autoReview, "gpt-5.6-luna", "gpt-reserve"].flatMap { parsedEvents(model: $0) }
        let scan = CodexLogUsageScanner.aggregate(
            events: events, since: .distantPast, pricing: TestPricing.bundled
        )
        let day = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(day.totalTokens, 330_000)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.0496, accuracy: 0.000_001)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.first(where: { $0.model == autoReview })?.costUSD, 0)
        for model in ["gpt-5.6-luna", "gpt-reserve"] {
            let entry = try XCTUnwrap(models.first(where: { $0.model == model }))
            XCTAssertEqual(entry.totalTokens, 110_000)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.0248, accuracy: 0.000_001)
        }
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testSharedCodexPricingRecognizesAutoReviewWithoutCatalogRates() throws {
        let tokens = TokenBreakdown(
            input: 300_000, cacheWrite5m: 20_000, cacheWrite1h: 10_000,
            cacheRead: 40_000, output: 10_000, isFast: true
        )
        for pricing in [TestPricing.bundled, .empty] {
            let prepared = try XCTUnwrap(CodexUsagePricing.prepare(pricing: pricing, model: autoReview))
            XCTAssertEqual(CodexUsagePricing.cost(prepared: prepared, tokens: tokens), 0)
            XCTAssertEqual(
                try XCTUnwrap(CodexUsagePricing.estimatedCost(pricing: pricing, model: autoReview, tokens: tokens)),
                0
            )
        }
    }

    func testFreeAutoReviewStaysVisibleInMixedAndAutoReviewOnlySpendTiles() throws {
        let autoEvents = parsedEvents()
        let now = try XCTUnwrap(autoEvents.first?.timestamp)
        for events in [autoEvents, autoEvents + parsedEvents(model: "gpt-5.6-luna")] {
            let scan = CodexLogUsageScanner.aggregate(
                events: events, since: .distantPast, pricing: TestPricing.bundled
            )
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: now, modelUsage: scan.modelUsage,
                modelSourceNote: "From Codex test logs"
            )
            for label in ["Today", "Last 30 Days"] {
                guard case .values(_, let values, _, _, let unknown, let breakdown) = lines.first(where: { $0.label == label }) else {
                    return XCTFail("Expected a \(label) spend row")
                }
                XCTAssertTrue(unknown.isEmpty)
                let detail = try XCTUnwrap(breakdown)
                let free = try XCTUnwrap(detail.models.first(where: { $0.model == autoReview }))
                XCTAssertEqual(free.totalTokens, 110_000)
                XCTAssertEqual(free.costUSD, 0)
                XCTAssertEqual(try XCTUnwrap(values.first?.number), events.count == 1 ? 0 : 0.0248, accuracy: 0.000_001)
                XCTAssertEqual(detail.totalTokens, events.count * 110_000)
                XCTAssertFalse(detail.models.contains(where: { $0.model == ModelUsageEntry.otherModelName }))
            }
        }
    }
}
