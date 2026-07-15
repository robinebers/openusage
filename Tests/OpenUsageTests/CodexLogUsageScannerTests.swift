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

    private func modelPricing(
        model: String,
        rates: ModelRates,
        supplementFastMultipliers: [String: Double] = [:]
    ) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(fastMultipliers: supplementFastMultipliers),
            primary: PricingCatalog(entries: [model: rates]),
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

    func testServiceTierTracksThreadSettingsAppliedLines() {
        // The tier comes from the session's own thread_settings_applied lines, per event: turns
        // before a priority switch stay standard, turns after a switch back to default do too.
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-07-12T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-07-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5)
            ),
            CodexLogFixture.threadSettingsApplied(timestamp: "2026-07-12T08:02:00.000Z", serviceTier: "priority"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-07-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 20, output: 10)
            ),
            CodexLogFixture.threadSettingsApplied(timestamp: "2026-07-12T08:04:00.000Z", serviceTier: "default"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-07-12T08:05:00.000Z",
                last: CodexLogFixture.usage(input: 30, output: 15)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.map(\.isFast), [false, true, false])
    }

    func testSessionWithoutServiceTierMetadataIsStandard() {
        // Rollouts written before Codex recorded the tier (or by older CLIs) carry no
        // thread_settings_applied line — they must price at standard rates, never at whatever
        // the current config.toml happens to say.
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.isFast), [false])
    }

    func testFastServiceTierAlsoMarksEventsFast() {
        let lines = [
            CodexLogFixture.threadSettingsApplied(timestamp: "2026-07-12T08:00:00.000Z", serviceTier: "fast"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-07-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5),
                model: "gpt-5.2"
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.isFast), [true])
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

    // MARK: - Child-session replay (subagents and forks)

    /// Epoch seconds of the child sessions' creation instant used across the replay tests.
    private var childCreationEpoch: Int {
        Int(OpenUsageISO8601.date(from: "2026-05-12T08:03:00.000Z")!.timeIntervalSince1970)
    }

    func testSubagentReplayLinesAreSkippedButSeedTheDeltaBaseline() {
        // A thread_spawn subagent file replays the parent's token_counts at spawn, then a live
        // task_started opens its own turns. Only the subagent's own turns count.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: childCreationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 1000, cached: 100, output: 200),
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.200Z",
                last: CodexLogFixture.usage(input: 500, cached: 50, output: 100),
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            ),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:01.000Z", startedAt: childCreationEpoch + 1),
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

    func testMultiSecondReplayIsFullySkipped() {
        // Regression for the ~20x spend inflation: a large parent history takes several seconds to
        // replay, so replayed lines land in many distinct timestamp seconds. All of them must be
        // skipped — only the turns after the live task_started count.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: childCreationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 1000, output: 200),
                totals: CodexLogFixture.usage(input: 1000, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:01.400Z",
                last: CodexLogFixture.usage(input: 2000, output: 400),
                totals: CodexLogFixture.usage(input: 3000, output: 600)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:02.800Z",
                last: CodexLogFixture.usage(input: 4000, output: 800),
                totals: CodexLogFixture.usage(input: 7000, output: 1400)
            ),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:03.000Z", startedAt: childCreationEpoch + 3),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:30.000Z",
                last: CodexLogFixture.usage(input: 100, output: 20)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].input, 100)
        XCTAssertEqual(events[0].output, 20)
    }

    func testForkSessionReplayIsSkippedToo() {
        // A fork (forked_from_id, no subagent source) replays parent history the same way.
        let lines = [
            CodexLogFixture.forkSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 1000, output: 200)
            ),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:05.000Z", startedAt: childCreationEpoch + 5),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:30.000Z",
                last: CodexLogFixture.usage(input: 50, output: 10)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.map(\.input), [50])
    }

    func testChildWithoutLiveTurnEmitsNothing() {
        // A child file that never reaches a live task_started is all replay — nothing counts.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: childCreationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 1000, output: 200)
            )
        ].joined(separator: "\n")

        XCTAssertTrue(CodexLogUsageScanner.parseFile(Data(lines.utf8)).isEmpty)
    }

    func testSubagentReplayBaselineMakesTotalsDeltasCorrect() {
        // The subagent's own lines carry only totals: the replayed totals must seed the baseline
        // so the first real turn doesn't re-count the parent's cumulative sum.
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: childCreationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.200Z",
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            ),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:01.000Z", startedAt: childCreationEpoch + 1),
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

    func testRootFileKeepsAllLines() {
        // A root session (no parent in its session_meta) skips nothing, even when lines share a
        // second and unrelated content mentions "thread_spawn".
        let lines = [
            CodexLogFixture.rootSessionMeta(timestamp: "2026-05-12T08:03:00.000Z"),
            #"{"timestamp":"2026-05-12T08:03:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"about thread_spawn"}}"#,
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

    func testRootSessionMetaWithNullParentFieldsIsNotTreatedAsChild() {
        // JSONSerialization represents JSON null as NSNull (not Swift nil). A root session that
        // declares forked_from_id / parent_thread_id / source.subagent as null must keep all lines.
        let sessionMeta = #"{"timestamp":"2026-05-12T08:03:00.000Z","type":"session_meta","payload":{"id":"root-abc","forked_from_id":null,"parent_thread_id":null,"source":{"subagent":null}}}"#
        let lines = [
            sessionMeta,
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 100, output: 20)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.500Z",
                last: CodexLogFixture.usage(input: 50, output: 10)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.input), [100, 50])
        XCTAssertFalse(CodexLogUsageScanner.isChildSessionMeta([
            "id": "root-abc",
            "forked_from_id": NSNull(),
            "parent_thread_id": NSNull(),
            "source": ["subagent": NSNull()]
        ]))
    }

    func testChildSessionMetaWithoutTimestampStillSkipsReplay() {
        // A child session_meta with no parseable creation timestamp must still suppress replayed
        // parent history. The gate clears on the first task_started whose started_at is at/after
        // that line's own wall-clock second.
        let sessionMeta = #"{"type":"session_meta","payload":{"id":"subagent-abc","forked_from_id":"parent-xyz"}}"#
        let lines = [
            sessionMeta,
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: childCreationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.100Z",
                last: CodexLogFixture.usage(input: 1000, output: 200)
            ),
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:05.000Z", startedAt: childCreationEpoch + 5),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:30.000Z",
                last: CodexLogFixture.usage(input: 50, output: 10)
            )
        ].joined(separator: "\n")

        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.input), [50])
    }

    func testFileWithoutSessionMetaKeepsAllLines() {
        // Older fixtures / truncated files with no session_meta at all: treat as a root session.
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

    func testUnchangedTotalsSnapshotIsSkippedEvenWithLastUsage() {
        // Codex re-emits stale token_count snapshots: same cumulative totals, repeated
        // last_token_usage, new timestamp. Only the first counts.
        let lines = [
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 1000, cached: 100, output: 200),
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                last: CodexLogFixture.usage(input: 1000, cached: 100, output: 200),
                totals: CodexLogFixture.usage(input: 1000, cached: 100, output: 200)
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.000Z",
                last: CodexLogFixture.usage(input: 500, cached: 50, output: 100),
                totals: CodexLogFixture.usage(input: 1500, cached: 150, output: 300)
            )
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].input, 1000)
        XCTAssertEqual(events[1].input, 500)
    }

    // MARK: - Aggregation

    private func makeEvent(
        _ timestamp: String, model: String = "gpt-5.2", input: Int = 100, cached: Int = 0,
        output: Int = 50, reasoning: Int = 0, isFast: Bool = false
    ) -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: OpenUsageISO8601.date(from: timestamp)!,
            model: model, input: input, cached: cached, output: output, reasoning: reasoning,
            total: input + output, isFast: isFast
        )
    }

    func testAggregateBucketsByLocalDayAndPrices() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [
                makeEvent("2026-05-12T08:00:00.000Z"),
                makeEvent("2026-05-12T09:00:00.000Z"),
                makeEvent("2026-05-13T08:00:00.000Z")
            ],
            since: .distantPast, pricing: fixedRates()
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
            events: [event], since: .distantPast, pricing: fixedRates()
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
            events: [event, event], since: .distantPast, pricing: fixedRates()
        )

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
    }

    func testAggregateCachedTokensPriceAtCacheReadRate() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z", input: 1000, cached: 400, output: 0)],
            since: .distantPast, pricing: fixedRates()
        )

        // 600 non-cached x $1000/M + 400 cached x $100/M = 0.6 + 0.04.
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.64, accuracy: 0.0001)
    }

    func testAggregateMissingCacheDiscountChargesCachedTokensAtFullInputRate() {
        let rates = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5,
            cacheReadIsExplicit: false
        )
        let scan = CodexLogUsageScanner.aggregate(
            events: [makeEvent(
                "2026-05-12T08:00:00.000Z", model: "gpt-test",
                input: 1000, cached: 400, output: 0
            )],
            since: .distantPast,
            pricing: modelPricing(model: "gpt-test", rates: rates)
        )

        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.005, accuracy: 0.000_001)
    }

    func testProModelWithoutCacheDiscountOverridesLegacySynthesizedRate() {
        let legacyRates = ModelRates(
            inputPerMillion: 30,
            outputPerMillion: 180,
            cacheWritePerMillion: 30,
            cacheReadPerMillion: 3,
            cacheReadIsExplicit: true
        )
        let event = makeEvent(
            "2026-05-12T08:00:00.000Z", model: "gpt-5.5-pro",
            input: 1000, cached: 400, output: 0
        )

        XCTAssertEqual(
            CodexLogUsageScanner.cost(
                rates: legacyRates, event: event, model: event.model,
                fastTier: false, fastMultiplier: 1
            ),
            0.03,
            accuracy: 0.000_001
        )
    }

    func testCodexLongContextRatesCoverSupportedModels() {
        let rates = ModelRates(
            inputPerMillion: 1,
            outputPerMillion: 1,
            cacheWritePerMillion: 1,
            cacheReadPerMillion: 0.1
        )
        let event = makeEvent(
            "2026-05-12T08:00:00.000Z", input: 300_000, cached: 100_000, output: 10_000
        )
        let expectedCosts: [(String, Double)] = [
            ("gpt-5.4", 1.275),
            ("gpt-5.4-pro-2026-03-05", 20.7),
            ("gpt-5.5", 2.55),
            ("gpt-5.5-pro-20260423", 20.7),
            ("gpt-5.6-sol", 2.55),
            ("gpt-5.6-terra", 1.275),
            ("gpt-5.6-luna", 0.51)
        ]

        for (model, expected) in expectedCosts {
            XCTAssertEqual(
                CodexLogUsageScanner.cost(
                    rates: rates, event: event, model: model,
                    fastTier: false, fastMultiplier: 1
                ),
                expected,
                accuracy: 0.000_001,
                model
            )
        }
    }

    func testCodexExactly272kInputKeepsBaseRates() {
        let rates = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5
        )
        let event = makeEvent(
            "2026-05-12T08:00:00.000Z", model: "gpt-5.5",
            input: 272_000, cached: 72_000, output: 1000
        )

        XCTAssertEqual(
            CodexLogUsageScanner.cost(
                rates: rates, event: event, model: "gpt-5.5",
                fastTier: false, fastMultiplier: 1
            ),
            1.066,
            accuracy: 0.000_001
        )
    }

    func testAggregateFastEventsDoubleWhenNoExplicitMultiplier() {
        let base = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z")],
            since: .distantPast, pricing: fixedRates()
        )
        let fast = CodexLogUsageScanner.aggregate(
            events: [makeEvent("2026-05-12T08:00:00.000Z", isFast: true)],
            since: .distantPast, pricing: fixedRates()
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

    func testAggregatePriorityTierUsesProviderSpecificModelMultipliers() {
        let rates = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5
        )
        let cases: [(model: String, supplementMultiplier: Double, expected: Double)] = [
            ("gpt-5.5", 2.5, 2.5),
            // Cursor's supplement currently says 2.5 for this model; Codex priority is 2x.
            ("gpt-5.6-sol", 2.5, 2)
        ]

        for entry in cases {
            let pricing = modelPricing(
                model: entry.model,
                rates: rates,
                supplementFastMultipliers: [entry.model: entry.supplementMultiplier]
            )
            let standard = CodexLogUsageScanner.aggregate(
                events: [makeEvent("2026-05-12T08:00:00.000Z", model: entry.model, input: 100, output: 50)],
                since: .distantPast, pricing: pricing
            )
            let priority = CodexLogUsageScanner.aggregate(
                events: [makeEvent(
                    "2026-05-12T08:00:00.000Z", model: entry.model, input: 100, output: 50, isFast: true
                )],
                since: .distantPast, pricing: pricing
            )

            XCTAssertEqual(
                priority.series.daily.first?.costUSD ?? 0,
                (standard.series.daily.first?.costUSD ?? 0) * entry.expected,
                accuracy: 0.000_001,
                entry.model
            )
        }
    }

    func testAggregateFastAliasUsesUnscaledCodexRatesAndProviderMultiplier() throws {
        let alias = PricingSupplement.AliasRule(
            pattern: try NSRegularExpression(pattern: #"^gpt-5\.6-sol-ultra-fast$"#),
            canonical: "gpt-5.6-sol-fast"
        )
        let rates = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 6.25,
            cacheReadPerMillion: 0.5
        )
        let pricing = ModelPricing(
            supplement: PricingSupplement(
                pricing: ["gpt-5.6-sol": rates],
                fastMultipliers: ["gpt-5.6-sol": 2.5],
                aliasRules: [alias]
            ),
            primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )

        let short = CodexLogUsageScanner.aggregate(
            events: [makeEvent(
                "2026-05-12T08:00:00.000Z", model: "gpt-5.6-sol-ultra-fast",
                input: 100_000, output: 10_000
            )],
            since: .distantPast,
            pricing: pricing
        )
        let long = CodexLogUsageScanner.aggregate(
            events: [makeEvent(
                "2026-05-12T09:00:00.000Z", model: "gpt-5.6-sol-ultra-fast",
                input: 300_000, cached: 100_000, output: 10_000
            )],
            since: .distantPast,
            pricing: pricing
        )

        // The alias itself selects Codex priority pricing: 2x the unscaled base/long-context
        // rates, not Cursor's 2.5x supplement variant and never both multipliers at once.
        XCTAssertEqual(short.series.daily.first?.costUSD ?? 0, 1.6, accuracy: 0.000_001)
        XCTAssertEqual(long.series.daily.first?.costUSD ?? 0, 5.1, accuracy: 0.000_001)
    }

    func testAggregateUnknownModelIsExcludedFromTotalsButWarns() {
        let scan = CodexLogUsageScanner.aggregate(
            events: [
                makeEvent("2026-05-12T08:00:00.000Z", model: "mystery-model-9"),
                makeEvent("2026-05-12T09:00:00.000Z")
            ],
            since: .distantPast, pricing: fixedRates()
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
            since: .distantPast, pricing: fixedRates()
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
            pricing: fixedRates()
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

    func testScanIgnoresConfigTomlServiceTier() async throws {
        // Regression: the tier used to be read from the *current* config.toml and applied to the
        // entire 30-day history, so toggling priority for one task retroactively ~doubled every
        // past day (and the synced iCloud history with it). The current config must not matter;
        // only the tier recorded in each session's log does.
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
            )
        ])
        try #"service_tier = "priority""#.write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: fixedRates())

        // Standard rates: (100 x $1000 + 50 x $3000) / 1M = $0.25 — no multiplier.
        XCTAssertEqual(scan?.series.daily.first?.costUSD ?? 0, 0.25, accuracy: 0.0001)
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
