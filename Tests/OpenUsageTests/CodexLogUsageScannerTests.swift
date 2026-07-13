import XCTest
@testable import OpenUsage

/// `CodexLogUsageScanner` against fixture rollout files — parsing, totals deltas, model tracking,
/// subagent replay skipping, dedup, aggregation, and the end-to-end scan. Fixture semantics ported
/// from ccusage's Codex adapter tests.
final class CodexLogUsageScannerTests: XCTestCase {
    private let pricing = TestPricing.bundled

    private func fixedRates(_ input: Double = 1000, _ output: Double = 3000) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                inputPerMillion: input, outputPerMillion: output,
                cacheWritePerMillion: input, cacheReadPerMillion: 100
            )]),
            secondary: PricingCatalog(entries: [:])
        )
    }

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
            since: .distantPast, pricing: fixedRates(), fastTier: false
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
            events: [event], since: .distantPast, pricing: fixedRates(), fastTier: false
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
            events: [event, event], since: .distantPast, pricing: fixedRates(), fastTier: false
        )

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
    }

    func testAggregateCachedTokensPriceAtCacheReadRate() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z", input: 1000, cached: 400, output: 0)],
            since: .distantPast, pricing: fixedRates(), fastTier: false
        )

        // 600 non-cached x $1000/M + 400 cached x $100/M = 0.6 + 0.04.
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.64, accuracy: 0.0001)
    }

    func testAggregateFastTierDoublesWhenNoExplicitMultiplier() {
        let base = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z")],
            since: .distantPast, pricing: fixedRates(), fastTier: false
        )
        let fast = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z")],
            since: .distantPast, pricing: fixedRates(), fastTier: true
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
            since: .distantPast, pricing: fixedRates(), fastTier: false
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
            since: .distantPast, pricing: fixedRates(), fastTier: false
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
            pricing: fixedRates(), fastTier: false
        )

        XCTAssertEqual(scan.series.daily.map(\.date), ["2026-05-12"])
    }

    // MARK: - End-to-end scan

    func testScanReadsSessionsAndArchivedSessions() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/2026/05/rollout-a.jsonl": [
                CodexLogFixture.turnContext(timestamp: day, model: "gpt-5.2"),
                CodexLogFixture.tokenCount(timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50))
            ].joined(separator: "\n"),
            "archived_sessions/rollout-b.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 30, output: 20), model: "gpt-5.2"
            )
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: fixedRates())

        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    func testScanPrefersActiveSessionsCopyOverArchivedDuplicate() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let content = CodexLogFixture.tokenCount(
            timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
        )
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": content,
            "archived_sessions/rollout-a.jsonl": content
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: fixedRates())

        // Same relative path in both dirs = the same session archived; identical events dedupe
        // anyway, but the discovery-level rule keeps it to one parse.
        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
    }

    func testScanKeepsDistinctFilesThroughSymlinkedHome() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        // The dedup keys are relative paths stripped of the source dir; discovery resolves symlinks,
        // so the strip must resolve too. With a link path longer than its target, an unresolved
        // strip overshoots and keys every file to "" — silently dropping all but the first.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("r", isDirectory: true)
        for (relativePath, content) in [
            "sessions/a.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
            ),
            "archived_sessions/b.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 30, output: 20), model: "gpt-5.2"
            )
        ] {
            let url = real.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let link = base.appendingPathComponent("a-codex-home-link-much-longer-than-its-resolved-target-path")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let scanner = CodexLogFixture.scanner(home: link)

        let scan = await scanner.scan(pricing: fixedRates())

        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    func testScanReturnsNilWithoutCodexHome() async {
        let scanner = CodexLogFixture.scanner(home: nil)
        let scan = await scanner.scan(pricing: fixedRates())
        XCTAssertNil(scan)
    }

    func testScanCachesUnchangedFilesAndPicksUpNewOnes() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
            )
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let first = await scanner.scan(pricing: fixedRates())
        XCTAssertEqual(first?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)

        try CodexLogFixture.tokenCount(
            timestamp: day, last: CodexLogFixture.usage(input: 30, output: 20), model: "gpt-5.2"
        ).write(to: home.appendingPathComponent("sessions/rollout-b.jsonl"), atomically: true, encoding: .utf8)

        let second = await scanner.scan(pricing: fixedRates())
        XCTAssertEqual(second?.series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    /// Manual parity harness against the real logs on this machine: prints per-day totals to compare
    /// with `ccusage codex daily --json --offline`. Gated like the other live tests.
    func testParityAgainstRealLocalLogs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_CODEX_PARITY"] == "1")
        let scanner = CodexLogUsageScanner()
        let result = await scanner.scan(pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        for day in scan.series.daily.sorted(by: { $0.date < $1.date }) {
            print("PARITY \(day.date) tokens=\(day.totalTokens) cost=\(day.costUSD.map { String(format: "%.4f", $0) } ?? "nil")")
        }
        if !scan.unknownModelsByDay.isEmpty {
            print("PARITY unknown models: \(scan.unknownModelsByDay)")
        }
    }

    func testScanPricesRealCodexModelsFromBundledSnapshots() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": [
                CodexLogFixture.turnContext(timestamp: day, model: "gpt-5.3-codex"),
                CodexLogFixture.tokenCount(
                    timestamp: day,
                    last: CodexLogFixture.usage(input: 1_000_000, output: 0)
                )
            ].joined(separator: "\n")
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: pricing)
        let today = scan?.series.daily.first

        // gpt-5.3-codex must resolve in the bundled LiteLLM snapshot and price > $0.
        XCTAssertTrue(scan?.unknownModelsByDay.isEmpty ?? false)
        XCTAssertGreaterThan(today?.costUSD ?? 0, 0)
    }
}
