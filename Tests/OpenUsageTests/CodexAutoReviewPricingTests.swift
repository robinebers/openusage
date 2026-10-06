import XCTest
@testable import OpenUsage

final class CodexAutoReviewPricingTests: XCTestCase {
    private let autoReview = "codex-auto-review"

    private func parsedEvents(date: String = "2026-10-06", model: String = "codex-auto-review") -> [CodexLogUsageScanner.Event] {
        parsedEvents(timestamp: "\(date)T08:01:00Z", model: model)
    }

    private func parsedEvents(timestamp: String, model: String = "codex-auto-review") -> [CodexLogUsageScanner.Event] {
        let lines = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: model),
            CodexLogFixture.tokenCount(
                timestamp: timestamp,
                last: CodexLogFixture.usage(input: 100_000, cached: 40_000, output: 10_000)
            )
        ].joined(separator: "\n")
        return CodexLogUsageScanner.parseFile(Data(lines.utf8))
    }

    func testHistoricalAutoReviewKeepsItsDatedPaidEstimatesAndMeasuredTokens() throws {
        for (timestamp, expectedModel, expectedCost) in [
            ("2026-03-10T08:01:00Z", "gpt-5.4", 0.31),
            ("2026-08-20T08:01:00Z", "gpt-5.6-luna", 0.0248),
            ("2026-10-05T23:59:59Z", "gpt-5.6-luna", 0.0248)
        ] {
            let event = try XCTUnwrap(parsedEvents(timestamp: timestamp).first)
            XCTAssertEqual(event.model, autoReview)
            XCTAssertEqual(CodexUsagePricing.pricingModel(for: autoReview, at: event.timestamp), expectedModel)
            let scan = CodexLogUsageScanner.aggregate(
                events: [event], since: .distantPast, pricing: TestPricing.bundled
            )
            XCTAssertEqual(scan.series.daily.count, 1)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000)
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001)
            let entry = try XCTUnwrap(scan.modelUsage?.daily.first?.models.first)
            XCTAssertEqual(entry.model, autoReview)
            XCTAssertEqual(entry.totalTokens, 110_000)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), expectedCost, accuracy: 0.000_001)
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
            XCTAssertNil(scan.fallbackPricingModelsByDay)
        }
    }

    func testFreePricingBeginsAtTheInclusiveUTCBoundaryWithoutCatalogRates() throws {
        XCTAssertEqual(
            CodexUsagePricing.autoReviewFreeSince,
            try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-06T00:00:00Z"))
        )
        for timestamp in ["2026-10-06T00:00:00Z", "2026-10-06T00:00:01Z", "2026-10-07T08:01:00Z"] {
            for pricing in [TestPricing.bundled, .empty] {
                let event = try XCTUnwrap(parsedEvents(timestamp: timestamp).first)
                XCTAssertEqual(CodexUsagePricing.pricingModel(for: autoReview, at: event.timestamp), autoReview)
                let scan = CodexLogUsageScanner.aggregate(events: [event], since: .distantPast, pricing: pricing)
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000)
                XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0)
                XCTAssertEqual(
                    scan.modelUsage?.daily.first?.models,
                    [ModelUsageEntry(model: autoReview, totalTokens: 110_000, costUSD: 0)]
                )
                XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                XCTAssertNil(scan.fallbackPricingModelsByDay)
            }
        }
    }

    func testOffsetTimestampsUseUTCInstantRatherThanLocalCalendarDate() throws {
        for (timestamp, expectedCost) in [
            ("2026-10-06T02:59:59+03:00", 0.0248),
            ("2026-10-05T17:00:00-07:00", 0.0)
        ] {
            let scan = CodexLogUsageScanner.aggregate(
                events: parsedEvents(timestamp: timestamp), since: .distantPast, pricing: TestPricing.bundled
            )
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001)
        }
    }

    func testMissingHistoricalRatesRemainUnknownAndExcludedBeforeTheBoundary() throws {
        for timestamp in ["2026-03-10T08:01:00Z", "2026-08-20T08:01:00Z", "2026-10-05T23:59:59Z"] {
            let event = try XCTUnwrap(parsedEvents(timestamp: timestamp).first)
            let scan = CodexLogUsageScanner.aggregate(events: [event], since: .distantPast, pricing: .empty)
            XCTAssertTrue(scan.series.daily.isEmpty)
            XCTAssertTrue(scan.modelUsage?.daily.isEmpty ?? true)
            XCTAssertEqual(scan.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: event.timestamp)], [autoReview])
            XCTAssertNil(scan.fallbackPricingModelsByDay)
        }
    }

    func testSelectedPaidFallbackOnlyEstimatesMissingHistoricalRates() throws {
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
        for (timestamp, expectedCost) in [
            ("2026-10-05T23:59:59Z", 0.62), ("2026-10-06T00:00:00Z", 0.0)
        ] {
            let event = try XCTUnwrap(parsedEvents(timestamp: timestamp).first)
            let scan = CodexLogUsageScanner.aggregate(
                events: [event], since: .distantPast, pricing: pricing, fallbackModel: fallback
            )
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000)
            let entry = try XCTUnwrap(scan.modelUsage?.daily.first?.models.first)
            XCTAssertEqual(entry.model, autoReview)
            XCTAssertEqual(entry.totalTokens, 110_000)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), expectedCost, accuracy: 0.000_001)
            if expectedCost == 0 {
                XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                XCTAssertNil(scan.fallbackPricingModelsByDay)
            } else {
                let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
                XCTAssertEqual(scan.unknownModelsByDay[day], [autoReview])
                XCTAssertEqual(scan.fallbackPricingModelsByDay?[day], [fallback])
            }
        }
    }

    func testCachedMappingsAndServiceTiersRespectTheEffectiveDate() throws {
        // Existing persistent caches may retain a paid pricing model or no explicit mapping.
        for pricingModel in [nil, "gpt-5.6-luna"] as [String?] {
            for (timestamp, isFree) in [
                ("2026-10-05T23:59:59Z", false), ("2026-10-06T00:00:00Z", true)
            ] {
                var event = try XCTUnwrap(parsedEvents(timestamp: timestamp).first)
                event.pricingModel = pricingModel
                for (input, baseCost) in [(100_000, 0.0248), (300_000, 0.1236)] {
                    for (fast, ultrafast) in [(false, false), (true, false), (false, true)] {
                        event.input = input
                        event.total = input + event.output
                        event.isFast = fast
                        event.isUltrafast = ultrafast
                        let scan = CodexLogUsageScanner.aggregate(
                            events: [event], since: .distantPast, pricing: TestPricing.bundled
                        )
                        let expectedCost = isFree ? 0 : baseCost * (fast || ultrafast ? 2 : 1)
                        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001)
                        XCTAssertEqual(scan.series.daily.first?.totalTokens, event.total)
                        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, autoReview)
                        XCTAssertEqual(
                            try XCTUnwrap(scan.modelUsage?.daily.first?.models.first?.costUSD),
                            expectedCost, accuracy: 0.000_001
                        )
                        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                        XCTAssertNil(scan.fallbackPricingModelsByDay)
                    }
                }
                let emptyScan = CodexLogUsageScanner.aggregate(events: [event], since: .distantPast, pricing: .empty)
                if isFree {
                    XCTAssertEqual(try XCTUnwrap(emptyScan.series.daily.first?.costUSD), 0)
                    XCTAssertTrue(emptyScan.unknownModelsByDay.isEmpty)
                } else {
                    XCTAssertTrue(emptyScan.series.daily.isEmpty)
                    XCTAssertEqual(emptyScan.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: event.timestamp)], [autoReview])
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

    func testSharedCodexPricingRequiresTheSameRequestTimeForEveryEntryPoint() throws {
        let tokens = TokenBreakdown(
            input: 60_000, cacheRead: 40_000, output: 10_000
        )
        for (timestamp, expectedCost) in [
            ("2026-10-05T23:59:59Z", 0.0248), ("2026-10-06T00:00:00Z", 0.0),
            ("2026-10-06T00:00:01Z", 0.0)
        ] {
            let date = try XCTUnwrap(OpenUsageISO8601.date(from: timestamp))
            let resolution = CodexUsagePricing.resolveRates(pricing: TestPricing.bundled, model: autoReview, at: date)
            XCTAssertNotNil(resolution.rates)
            XCTAssertEqual(resolution.rateModel, expectedCost == 0 ? autoReview : "gpt-5.6-luna")
            let prepared = try XCTUnwrap(CodexUsagePricing.prepare(pricing: TestPricing.bundled, model: autoReview, at: date))
            XCTAssertEqual(CodexUsagePricing.cost(prepared: prepared, tokens: tokens), expectedCost, accuracy: 0.000_001)
            XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimatedCost(
                pricing: TestPricing.bundled, model: autoReview, tokens: tokens, at: date
            )), expectedCost, accuracy: 0.000_001)

            let emptyPrepared = CodexUsagePricing.prepare(pricing: .empty, model: autoReview, at: date)
            let emptyCost = CodexUsagePricing.estimatedCost(pricing: .empty, model: autoReview, tokens: tokens, at: date)
            if expectedCost == 0 {
                XCTAssertEqual(CodexUsagePricing.cost(prepared: try XCTUnwrap(emptyPrepared), tokens: tokens), 0)
                XCTAssertEqual(try XCTUnwrap(emptyCost), 0)
            } else {
                XCTAssertNil(emptyPrepared)
                XCTAssertNil(emptyCost)
                XCTAssertNil(CodexUsagePricing.resolveRates(pricing: .empty, model: autoReview, at: date).rates)
            }
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
