import XCTest
@testable import OpenUsage

enum CodexLogUsageScannerTestFixtures {
    static func fixedRates(_ input: Double = 1000, _ output: Double = 3000) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                inputPerMillion: input, outputPerMillion: output,
                cacheWritePerMillion: input, cacheReadPerMillion: 100
            )]),
            secondary: PricingCatalog(entries: [:])
        )
    }
}

/// `CodexLogUsageScanner` against fixture rollout files — parsing, totals deltas, model tracking,
/// subagent replay skipping, dedup, and aggregation. Fixture semantics are ported
/// from ccusage's Codex adapter tests.
final class CodexLogUsageScannerTests: XCTestCase {
    // MARK: - Line parsing

    func testLastTokenUsageWinsOverTotalsDelta() {
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 1000, cached: 100, output: 200),
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                last: CodexLogFixture.usage(input: 500, cached: 50, output: 100),
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].input, 1000)
        XCTAssertEqual(events[0].cached, 100)
        XCTAssertEqual(events[0].output, 200)
        XCTAssertEqual(events[0].model, "gpt-5.2")
        XCTAssertEqual(events[1].input, 500)
        XCTAssertEqual(events[1].total, 600)
    }

    func testTotalsOnlyLinesEmitDeltas() {
        // Older rollouts carry only the cumulative counter; each line's usage is the delta.
        let lines = [
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].input, 1000)
        XCTAssertEqual(events[1].input, 500)
        XCTAssertEqual(events[1].cached, 50)
        XCTAssertEqual(events[1].output, 100)
        XCTAssertEqual(events[1].total, 600)
    }

    func testZeroUsageLinesAreSkipped() {
        let lines = [
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 0, output: 0)
            ),
            // Totals repeat (no growth) -> zero delta -> skipped too.
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                totals: CodexLogFixture.usage(input: 100, output: 50)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                totals: CodexLogFixture.usage(input: 100, output: 50)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].input, 100)
    }

    func testModelComesFromTurnContextAndFallsBackToGpt5() {
        let noContext = CodexLogFixture.tokenCount(
            timestamp: "2026-05-12T08:01:00.000Z",
            last: CodexLogFixture.usage(input: 10, output: 5)
        )
        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(noContext.utf8)).first?.model, "gpt-5")

        let withContext = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00.000Z", model: "gpt-5.3-codex"),
            noContext
        ].joined(separator: "\n")
        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(withContext.utf8)).first?.model, "gpt-5.3-codex")
    }

    func testInlineModelOnTokenCountOverridesTurnContext() {
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5),
                model: "gpt-5.4"
            ),
            // The inline model becomes the session's current model for later lines.
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                last: CodexLogFixture.usage(input: 20, output: 10)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.map(\.model), ["gpt-5.4", "gpt-5.4"])
    }

    func testCachedTokensCapAtInputTokens() {
        let line = CodexLogFixture.tokenCount(
            timestamp: "2026-05-12T08:01:00.000Z",
            last: CodexLogFixture.usage(input: 100, cached: 250, output: 10)
        )
        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(line.utf8)).first?.cached, 100)
    }

    // MARK: - Auto-review fallbacks

    func testAutoReviewSlugMapsToDatedCodexModel() {
        XCTAssertEqual(CodexLogUsageScanner.autoReviewFallback(at: "2026-05-01T00:00:00Z"), "gpt-5.5")
        XCTAssertEqual(CodexLogUsageScanner.autoReviewFallback(at: "2026-03-10T00:00:00Z"), "gpt-5.4")
        XCTAssertEqual(CodexLogUsageScanner.autoReviewFallback(at: "2025-12-25T00:00:00Z"), "gpt-5.2-codex")
        XCTAssertEqual(CodexLogUsageScanner.autoReviewFallback(at: "2025-01-01T00:00:00Z"), "gpt-5")
        XCTAssertEqual(CodexLogUsageScanner.autoReviewFallback(at: "garbage"), "gpt-5")
    }

    func testAutoReviewLinesResolveByLineDate() {
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-03-10T08:00:00.000Z", model: "codex-auto-review"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-03-10T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).first?.model, "gpt-5.4")
    }

    // MARK: - Subagent replay

    func testSubagentReplayLinesAreSkippedButSeedTheDeltaBaseline() {
        // Ported from ccusage: a thread_spawn subagent file replays the parent's two token_counts
        // at its creation second, then logs its own turns. Only the subagent's own turns count.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 1000, cached: 100, output: 200),
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 500, cached: 50, output: 100),
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:04:00.000Z",
                last: CodexLogFixture.usage(input: 100, cached: 10, output: 20),
                model: "gpt-5.2"
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:05:00.000Z",
                last: CodexLogFixture.usage(input: 50, cached: 5, output: 10)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].input, 100)
        XCTAssertEqual(events[0].output, 20)
        XCTAssertEqual(events[1].input, 50)
        XCTAssertEqual(events[1].output, 10)
    }

    func testSubagentReplayBaselineMakesTotalsDeltasCorrect() {
        // Same replay, but the subagent's own lines carry only totals: the replayed totals must
        // seed the baseline so the first real turn doesn't re-count the parent's cumulative sum.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:04:00.000Z",
                totals: CodexLogFixture.usage(input: 1600, cached: 160, output: 320)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].input, 100)
        XCTAssertEqual(events[0].cached, 10)
        XCTAssertEqual(events[0].output, 20)
    }

    func testParentFileWithoutThreadSpawnKeepsAllLines() {
        // Two token_counts in the same second in a NON-subagent file must both count.
        let lines = [
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 100, output: 20)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.500Z",
                last: CodexLogFixture.usage(input: 50, output: 10)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).count, 2)
    }

    func testSubagentWithDistinctFirstSecondsSkipsNothing() {
        // thread_spawn marker present but the first two usage lines land in different seconds ->
        // no replay burst detected -> everything counts.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 100, output: 20)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:04:00.000Z",
                last: CodexLogFixture.usage(input: 50, output: 10)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).count, 2)
    }

    // MARK: - Aggregation

    private func makeEvent(
        _ timestamp: String, model: String = "gpt-5.2", input: Int = 100, cached: Int = 0,
        output: Int = 50, reasoning: Int = 0
    ) -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: OpenUsageISO8601.date(from: timestamp)!,
            model: model, input: input, cached: cached, output: output, reasoning: reasoning,
            total: input + output
        )
    }

    func testAggregateBucketsByLocalDayAndPrices() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [
                makeEvent("2026-05-12T08:00:00.000Z"),
                makeEvent("2026-05-12T09:00:00.000Z"),
                makeEvent("2026-05-13T08:00:00.000Z")
            ],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        XCTAssertEqual(scan.series.daily.count, 2)
        // (100 x $1000 + 50 x $3000) / 1M = $0.25 per event.
        let may12 = scan.series.daily.first { $0.date == "2026-05-12" }
        XCTAssertEqual(may12?.totalTokens, 300)
        XCTAssertEqual(may12?.costUSD ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        let may12Models = scan.modelUsage?.daily.first { $0.date == "2026-05-12" }?.models ?? []
        XCTAssertEqual(may12Models, [ModelUsageEntry(model: "gpt-5.2", totalTokens: 300, costUSD: 0.5)])
    }

    func testAggregateFeedsSingleModelTodayBreakdown() throws {
        let now = Date()
        let event = CodexLogUsageScanner.Event(
            timestamp: now,
            model: "gpt-5.2",
            input: 100,
            cached: 0,
            output: 50,
            reasoning: 0,
            total: 150
        )
        let scan = CodexLogUsageScanner.aggregate(
            events: [event], since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: "From Codex test logs"
        )

        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("Expected a Today spend row")
        }
        let today = try XCTUnwrap(breakdown)
        XCTAssertEqual(today.models, [ModelUsageEntry(model: "gpt-5.2", totalTokens: 150, costUSD: 0.25)])
    }

    func testAggregateDropsIdenticalEventsAcrossFiles() {
        // The same event parsed from a copied session file counts once.
        let event = makeEvent("2026-05-12T08:00:00.000Z")
        let scan = CodexLogUsageScanner.aggregate(
            events: [event, event], since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
    }

    func testAggregateCachedTokensPriceAtCacheReadRate() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z", input: 1000, cached: 400, output: 0)],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        // 600 non-cached x $1000/M + 400 cached x $100/M = 0.6 + 0.04.
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.64, accuracy: 0.0001)
    }

    func testAggregateFastTierDoublesWhenNoExplicitMultiplier() {
        let base = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z")],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )
        let fast = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z")],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: true
        )

        XCTAssertEqual(
            fast.series.daily.first?.costUSD ?? 0,
            (base.series.daily.first?.costUSD ?? 0) * 2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            fast.modelUsage?.daily.first?.models.first?.costUSD ?? 0,
            (base.modelUsage?.daily.first?.models.first?.costUSD ?? 0) * 2,
            accuracy: 0.0001
        )
    }

    func testAggregateUnknownModelIsExcludedFromTotalsButWarns() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [
                makeEvent("2026-05-12T08:00:00.000Z", model: "mystery-model-9"),
                makeEvent("2026-05-12T09:00:00.000Z")
            ],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        // Unpriceable tokens never enter the displayed totals — they surface only through the
        // warning triangle, so the tile's tokens and dollars stay coherent.
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
        XCTAssertNotNil(scan.series.daily.first?.costUSD)
        XCTAssertEqual(scan.unknownModelsByDay["2026-05-12"], ["mystery-model-9"])
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.map(\.model), ["gpt-5.2"])
    }

    func testAggregateUnknownModelOnlyLeavesDayUnbacked() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z", model: "mystery-model-9")],
            since: .distantPast, pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        // A day with nothing priceable produces no series entry at all (→ "No data"), but the
        // unknown-model warning still names what was excluded.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay["2026-05-12"], ["mystery-model-9"])
        XCTAssertEqual(scan.modelUsage?.daily ?? [], [])
    }

    func testAggregateFiltersEventsBeforeSince() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-01-01T08:00:00.000Z"), makeEvent("2026-05-12T08:00:00.000Z")],
            since: OpenUsageISO8601.date(from: "2026-05-01T00:00:00.000Z")!,
            pricing: CodexLogUsageScannerTestFixtures.fixedRates(), fastTier: false
        )

        XCTAssertEqual(scan.series.daily.map(\.date), ["2026-05-12"])
    }

}
