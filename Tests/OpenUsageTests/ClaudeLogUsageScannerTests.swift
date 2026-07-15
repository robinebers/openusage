import XCTest
@testable import OpenUsage

/// Line parsing, deduplication, and day aggregation for the native Claude log scanner — the
/// dedup/validity fixtures are ported from ccusage's Claude adapter tests so the two agree on
/// what counts.
final class ClaudeLogUsageScannerTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    /// Deterministic fixture pricing: input $10/M, output $20/M, cache write $12.5/M, read $1/M.
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "claude-test-model": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 12.5, cacheReadPerMillion: 1,
                fastMultiplier: 2
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func localDay(_ iso: String) -> String {
        let date = OpenUsageISO8601.date(from: iso)!
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    // MARK: - Line parsing

    func testParsesModernLineWithCacheSplitAndSpeed() throws {
        let line = """
        {"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","version":"1.0.24",\
        "isSidechain":true,"costUSD":0.5,"message":{"id":"msg_1","model":"claude-test-model",\
        "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,\
        "cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}
        """
        let entry = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(Data(line.utf8)))
        XCTAssertEqual(entry.tokens, TokenBreakdown(
            input: 100, cacheWrite5m: 20, cacheWrite1h: 10, cacheRead: 30, output: 50, isFast: true
        ))
        XCTAssertEqual(entry.messageID, "msg_1")
        XCTAssertEqual(entry.requestID, "req_1")
        XCTAssertTrue(entry.isSidechain)
        XCTAssertTrue(entry.hasSpeed)
        XCTAssertEqual(entry.costUSD, 0.5)
        XCTAssertEqual(entry.model, "claude-test-model")
    }

    func testLegacyAggregateCacheCreationCountsAsFiveMinuteWrites() throws {
        let line = ClaudeLogFixture.usageLine(
            timestamp: "2026-02-20T12:00:00.000Z", input: 10, output: 5, cacheWrite: 40, cacheRead: 7
        )
        let entry = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(Data(line.utf8)))
        XCTAssertEqual(entry.tokens, TokenBreakdown(
            input: 10, cacheWrite5m: 40, cacheWrite1h: 0, cacheRead: 7, output: 5
        ))
        XCTAssertFalse(entry.hasSpeed)
        XCTAssertNil(entry.costUSD)
    }

    func testLogReportedStandardSpeedRemainsAuthoritativeAfterFastModeChange() throws {
        let line = #"{"timestamp":"2026-06-30T12:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":10,"output_tokens":5,"speed":"standard"}}}"#

        let entry = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(Data(line.utf8)))

        XCTAssertTrue(entry.hasSpeed)
        XCTAssertFalse(entry.tokens.isFast)
    }

    func testRejectsLinesTheCcusageSchemaRejects() {
        // Missing usage.input_tokens / output_tokens.
        XCTAssertNil(ClaudeLogUsageScanner.parseLine(Data(
            #"{"timestamp":"2026-02-20T12:00:00Z","message":{"usage":{"output_tokens":5}}}"#.utf8
        )))
        // Unparseable timestamp.
        XCTAssertNil(ClaudeLogUsageScanner.parseLine(Data(
            #"{"timestamp":"not-a-date","message":{"usage":{"input_tokens":1,"output_tokens":2}}}"#.utf8
        )))
        // Unknown speed value (ccusage's lowercase enum parse fails the line).
        XCTAssertNil(ClaudeLogUsageScanner.parseLine(Data(
            #"{"timestamp":"2026-02-20T12:00:00Z","message":{"usage":{"input_tokens":1,"output_tokens":2,"speed":"turbo"}}}"#.utf8
        )))
        // Non-semver version marks a foreign log shape.
        XCTAssertNil(ClaudeLogUsageScanner.parseLine(Data(
            ClaudeLogFixture.usageLine(timestamp: "2026-02-20T12:00:00Z", version: "unknown").utf8
        )))
        // Present-but-empty model.
        XCTAssertNil(ClaudeLogUsageScanner.parseLine(Data(
            ClaudeLogFixture.usageLine(timestamp: "2026-02-20T12:00:00Z", model: "").utf8
        )))
    }

    func testSyntheticModelKeepsEntryWithoutModel() throws {
        let line = ClaudeLogFixture.usageLine(
            timestamp: "2026-02-20T12:00:00.000Z", model: "<synthetic>", input: 5, output: 5
        )
        let entry = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(Data(line.utf8)))
        XCTAssertNil(entry.model)
        XCTAssertEqual(entry.tokens.totalTokens, 10)
    }

    func testSemverPrefix() {
        XCTAssertTrue(ClaudeLogUsageScanner.isSemverPrefix("1.0.24"))
        XCTAssertTrue(ClaudeLogUsageScanner.isSemverPrefix("1.0.24-beta.1"))
        XCTAssertFalse(ClaudeLogUsageScanner.isSemverPrefix("unknown"))
        XCTAssertFalse(ClaudeLogUsageScanner.isSemverPrefix("1.0"))
        XCTAssertFalse(ClaudeLogUsageScanner.isSemverPrefix("1.0."))
    }

    // Ported from ccusage `rejects_null_schema_fields_like_typescript_loader`.
    func testRejectsNullSchemaFields() {
        XCTAssertTrue(ClaudeLogUsageScanner.hasUnsupportedNullField(Data(
            #"{"message":{"usage":{"speed":null}}}"#.utf8
        )))
        XCTAssertTrue(ClaudeLogUsageScanner.hasUnsupportedNullField(Data(
            #"{"message":{"model":null,"usage":{"input_tokens":0}}}"#.utf8
        )))
        XCTAssertTrue(ClaudeLogUsageScanner.hasUnsupportedNullField(Data(
            #"{"sessionId":null,"message":{"usage":{"input_tokens":0}}}"#.utf8
        )))
        // `content: null` is fine — only the known schema fields reject nulls.
        XCTAssertFalse(ClaudeLogUsageScanner.hasUnsupportedNullField(Data(
            #"{"message":{"content":null,"usage":{"input_tokens":0}}}"#.utf8
        )))
    }

    func testParseFileSkipsNonUsageAndMalformedLines() {
        let content = """
        {"type":"summary","summary":"not a usage line"}
        not json at all
        \(ClaudeLogFixture.usageLine(timestamp: "2026-02-20T12:00:00.000Z", input: 1, output: 2))
        {"timestamp":"2026-02-20T12:00:00Z","message":{"usage":{"speed":null}}}
        """
        let entries = ClaudeLogUsageScanner.parseFile(Data(content.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].tokens.totalTokens, 3)
    }

    func testPersistedPrintModeUsageCountsLikeInteractiveUsage() throws {
        // `claude -p` writes the same assistant usage record with the `sdk-cli` entrypoint unless
        // the caller explicitly passes `--no-session-persistence`.
        let line = #"{"type":"assistant","entrypoint":"sdk-cli","timestamp":"2026-02-20T12:00:00.000Z","sessionId":"print-session","requestId":"print-request","version":"2.1.207","message":{"id":"print-message","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"speed":"standard"}}}"#

        let entries = ClaudeLogUsageScanner.parseFile(Data(line.utf8))
        let entry = try XCTUnwrap(entries.first)
        let scan = ClaudeLogUsageScanner.aggregate(
            entries: entries,
            since: .distantPast,
            pricing: pricing
        )

        XCTAssertEqual(entry.tokens.totalTokens, 190)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 190)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.001_815, accuracy: 0.000_000_001)
    }

    func testParseFileExpandsOnlyAdvisorIterationsWithoutRecountingMainUsage() {
        let line = #"{"timestamp":"2026-02-20T12:00:00.000Z","requestId":"req_1","costUSD":1.23,"message":{"id":"msg_1","model":"main-model","usage":{"input_tokens":2,"output_tokens":491,"cache_creation_input_tokens":7853,"cache_read_input_tokens":226584,"iterations":[{"type":"message","input_tokens":1,"output_tokens":200},{"type":"advisor_message","model":"claude-test-model","input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4},{"type":"message","input_tokens":1,"output_tokens":291}]}}}"#

        let entries = ClaudeLogUsageScanner.parseFile(Data(line.utf8))

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].model, "main-model")
        XCTAssertEqual(entries[0].tokens, TokenBreakdown(
            input: 2, cacheWrite5m: 7853, cacheRead: 226584, output: 491
        ))
        XCTAssertEqual(entries[0].costUSD, 1.23)
        XCTAssertEqual(entries[1].model, "claude-test-model")
        XCTAssertEqual(entries[1].messageID, "msg_1:advisor:0")
        XCTAssertEqual(entries[1].requestID, "req_1")
        XCTAssertEqual(entries[1].tokens, TokenBreakdown(
            input: 10, cacheWrite5m: 3, cacheRead: 4, output: 2
        ))
        XCTAssertNil(entries[1].costUSD)
    }

    func testAdvisorIterationUsesItsOwnModelPriceAlongsideParentCarriedCost() {
        let line = #"{"timestamp":"2026-02-20T12:00:00.000Z","requestId":"req_1","costUSD":1.23,"message":{"id":"msg_1","model":"main-model","usage":{"input_tokens":1,"output_tokens":2,"iterations":[{"type":"advisor_message","model":"claude-test-model","input_tokens":10,"output_tokens":2}]}}}"#
        let entries = ClaudeLogUsageScanner.parseFile(Data(line.utf8))

        let scan = ClaudeLogUsageScanner.aggregate(
            entries: ClaudeLogUsageScanner.dedup(entries), since: .distantPast, pricing: pricing
        )

        // Parent: carried $1.23. Advisor: 10 input at $10/M + 2 output at $20/M.
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 1.23014, accuracy: 1e-9)
        let models = scan.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == "main-model" }?.costUSD, 1.23)
        XCTAssertEqual(
            models.first { $0.model == "claude-test-model" }?.costUSD ?? 0, 0.00014, accuracy: 1e-9
        )
    }

    // MARK: - Deduplication (ported from ccusage)

    private func entry(
        messageID: String?, requestID: String?, isSidechain: Bool, cacheRead: Int, output: Int,
        hasSpeed: Bool = false
    ) -> Entry {
        Entry(
            timestamp: OpenUsageISO8601.date(from: "2026-02-20T12:00:00.000Z")!,
            tokens: TokenBreakdown(cacheRead: cacheRead, output: output),
            messageID: messageID,
            requestID: requestID,
            isSidechain: isSidechain,
            hasSpeed: hasSpeed,
            costUSD: nil,
            model: "claude-test-model"
        )
    }

    // Ported from `keeps_parent_usage_when_sidechain_replays_message_with_new_request_id`.
    func testKeepsParentUsageWhenSidechainReplaysMessageWithNewRequestID() {
        let deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: "msg-parent", requestID: "req-parent", isSidechain: false, cacheRead: 20, output: 10),
            entry(messageID: "msg-parent", requestID: "req-sidechain-replay", isSidechain: true, cacheRead: 50_000, output: 10),
            entry(messageID: "msg-sidechain-answer", requestID: "req-sidechain-answer", isSidechain: true, cacheRead: 700, output: 30)
        ])
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped[0].requestID, "req-parent")
        XCTAssertEqual(deduped[0].tokens.cacheRead, 20)
        XCTAssertEqual(deduped[1].messageID, "msg-sidechain-answer")
        XCTAssertEqual(deduped[1].tokens.cacheRead, 700)
    }

    // Ported from `refreshes_dedupe_indexes_when_parent_replaces_sidechain_replay`.
    func testParentReplacesSidechainReplayAndIndexesStayFresh() {
        let deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: "msg-parent", requestID: "req-sidechain-replay", isSidechain: true, cacheRead: 50_000, output: 10),
            entry(messageID: "msg-parent", requestID: "req-parent", isSidechain: false, cacheRead: 20, output: 10),
            entry(messageID: "msg-parent", requestID: "req-parent", isSidechain: false, cacheRead: 5, output: 5)
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].requestID, "req-parent")
        XCTAssertEqual(deduped[0].tokens.cacheRead, 20)
    }

    func testDistinctRequestIDsWithoutSidechainAreBothKept() {
        let deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: "msg-1", requestID: "req-a", isSidechain: false, cacheRead: 1, output: 1),
            entry(messageID: "msg-1", requestID: "req-b", isSidechain: false, cacheRead: 2, output: 2)
        ])
        XCTAssertEqual(deduped.count, 2)
    }

    func testExactDuplicateKeepsLargerTokenTotalThenSpeedTiebreak() {
        // Same (messageID, requestID): the larger token total wins…
        var deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: "msg-1", requestID: "req-1", isSidechain: false, cacheRead: 10, output: 10),
            entry(messageID: "msg-1", requestID: "req-1", isSidechain: false, cacheRead: 100, output: 10)
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].tokens.cacheRead, 100)

        // …and on an equal total, the entry carrying a `speed` field wins.
        deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: "msg-2", requestID: "req-2", isSidechain: false, cacheRead: 10, output: 10),
            entry(messageID: "msg-2", requestID: "req-2", isSidechain: false, cacheRead: 10, output: 10, hasSpeed: true)
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].hasSpeed)
    }

    func testEntriesWithoutMessageIDAreNeverDeduped() {
        let deduped = ClaudeLogUsageScanner.dedup([
            entry(messageID: nil, requestID: "req-1", isSidechain: false, cacheRead: 1, output: 1),
            entry(messageID: nil, requestID: "req-1", isSidechain: false, cacheRead: 1, output: 1)
        ])
        XCTAssertEqual(deduped.count, 2)
    }

    // MARK: - Aggregation

    func testAggregateUsesCarriedCostAndComputesTheRest() {
        let day = localDay("2026-02-20T12:00:00.000Z")
        var carried = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        carried.costUSD = 0.75
        carried.tokens = TokenBreakdown(input: 100, output: 50)
        // Computed from the fixture rates: 1000 input = $0.01, 500 output = $0.01.
        var computed = entry(messageID: "m2", requestID: "r2", isSidechain: false, cacheRead: 0, output: 0)
        computed.tokens = TokenBreakdown(input: 1000, output: 500)

        let scan = ClaudeLogUsageScanner.aggregate(
            entries: [carried, computed], since: .distantPast, pricing: pricing
        )

        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].date, day)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 1650)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.75 + 0.02, accuracy: 1e-9)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        let models = scan.modelUsage?.daily.first { $0.date == day }?.models ?? []
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "claude-test-model")
        XCTAssertEqual(models.first?.totalTokens, 1650)
        XCTAssertEqual(models.first?.costUSD ?? 0, 0.77, accuracy: 1e-9)
    }

    func testAggregateFastSpeedAppliesMultiplier() {
        var fast = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        fast.tokens = TokenBreakdown(input: 1000, output: 500, isFast: true)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [fast], since: .distantPast, pricing: pricing)

        // Fixture fastMultiplier is 2: ($0.01 + $0.01) * 2.
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.04, accuracy: 1e-9)
    }

    func testAggregateUnknownModelIsExcludedFromTotalsButWarns() {
        let day = localDay("2026-02-20T12:00:00.000Z")
        var unknown = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        unknown.model = "mystery-model"
        unknown.tokens = TokenBreakdown(input: 10, output: 5)
        var priced = entry(messageID: "m2", requestID: "r2", isSidechain: false, cacheRead: 0, output: 0)
        priced.tokens = TokenBreakdown(input: 1000, output: 500)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [unknown, priced], since: .distantPast, pricing: pricing)

        // Unpriceable tokens never enter the displayed totals — they surface only through the
        // warning triangle, so the tile's tokens and dollars stay coherent.
        XCTAssertEqual(scan.series.daily, [DailyUsageEntry(date: day, totalTokens: 1500, costUSD: 0.02)])
        XCTAssertEqual(scan.unknownModelsByDay[day], ["mystery-model"])
        XCTAssertEqual(scan.modelUsage?.daily.first?.models, [
            ModelUsageEntry(model: "claude-test-model", totalTokens: 1500, costUSD: 0.02)
        ])
    }

    func testAggregateUnknownModelOnlyLeavesDayUnbacked() {
        let day = localDay("2026-02-20T12:00:00.000Z")
        var unknown = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        unknown.model = "mystery-model"
        unknown.tokens = TokenBreakdown(input: 10, output: 5)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [unknown], since: .distantPast, pricing: pricing)

        // A day with nothing priceable produces no series entry at all (→ "No data"), but the
        // unknown-model warning still names what was excluded.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay[day], ["mystery-model"])
        XCTAssertEqual(scan.modelUsage?.daily ?? [], [])
    }

    func testAggregateSyntheticModelIsExcludedWithoutWarning() {
        var synthetic = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        synthetic.model = nil
        synthetic.tokens = TokenBreakdown(input: 10, output: 5)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [synthetic], since: .distantPast, pricing: pricing)

        // No model and no carried cost: unpriceable, so excluded from totals — and with no name to
        // warn about, no unknown-model entry either.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily ?? [], [])
    }

    func testAggregateSyntheticModelWithCarriedCostStillCounts() {
        // A cost the log itself carries is priced regardless of the missing model name — only
        // unpriceable usage is excluded.
        var synthetic = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        synthetic.model = nil
        synthetic.costUSD = 0.10
        synthetic.tokens = TokenBreakdown(input: 10, output: 5)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [synthetic], since: .distantPast, pricing: pricing)

        XCTAssertEqual(scan.series.daily[0].totalTokens, 15)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.10, accuracy: 1e-9)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models, [
            ModelUsageEntry(model: ModelUsageEntry.unattributedModelName, totalTokens: 15, costUSD: 0.10)
        ])
    }

    func testAggregateFiltersEntriesBeforeSince() {
        let since = OpenUsageISO8601.date(from: "2026-02-01T00:00:00.000Z")!
        var old = entry(messageID: "m1", requestID: "r1", isSidechain: false, cacheRead: 0, output: 0)
        old.timestamp = OpenUsageISO8601.date(from: "2026-01-15T12:00:00.000Z")!
        old.tokens = TokenBreakdown(input: 100, output: 100)

        let scan = ClaudeLogUsageScanner.aggregate(entries: [old], since: since, pricing: pricing)

        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    // MARK: - End-to-end scan

    func testScanReadsFixtureHomeAndRescanPicksUpNewLines() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session-1.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                messageID: "msg-1", requestID: "req-1"
            )
        ])
        let scanner = ClaudeLogFixture.scanner(home: home)

        let firstScan = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstScan)
        XCTAssertEqual(first.series.daily.count, 1)
        XCTAssertEqual(first.series.daily[0].totalTokens, 150)
        XCTAssertEqual(first.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)

        // Append a second session file; the rescan must pick it up (per-file cache invalidation).
        let newFile = home.appendingPathComponent("projects/project-a/session-2.jsonl")
        try ClaudeLogFixture.usageLine(
            timestamp: timestamp, input: 10, output: 5, costUSD: 0.05,
            messageID: "msg-2", requestID: "req-2"
        ).write(to: newFile, atomically: true, encoding: .utf8)

        let secondScan = await scanner.scan(now: now, pricing: pricing)
        let second = try XCTUnwrap(secondScan)
        XCTAssertEqual(second.series.daily[0].totalTokens, 165)
        XCTAssertEqual(second.series.daily[0].costUSD ?? 0, 0.30, accuracy: 1e-9)
    }

    func testScanDeduplicatesReplaysAcrossFiles() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        // The same message replayed in a sidechain session file under a new request id: only the
        // parent's tokens may count.
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/parent.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                messageID: "msg-shared", requestID: "req-parent", isSidechain: false
            ),
            "project-a/sidechain.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 90_000, output: 10, costUSD: 9.99,
                messageID: "msg-shared", requestID: "req-replay", isSidechain: true
            )
        ])
        let scanner = ClaudeLogFixture.scanner(home: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 150)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)
    }

    func testScanSkipsFilesLastTouchedBeforeTheWindow() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/old.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now.addingTimeInterval(-90 * 86_400)),
                input: 100, output: 50, costUSD: 0.25
            )
        ])
        let oldFile = home.appendingPathComponent("projects/project-a/old.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: oldFile.path
        )
        let scanner = ClaudeLogFixture.scanner(home: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    func testScanReturnsNilWithoutClaudeHome() async {
        let scanner = ClaudeLogFixture.scanner(home: nil)
        let scan = await scanner.scan(now: Date(), pricing: pricing)
        XCTAssertNil(scan)
    }

    /// Manual parity harness against the real logs on this machine: prints per-day totals to compare
    /// with `ccusage daily --json --offline`. Gated like the other live tests.
    func testParityAgainstRealLocalLogs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_CLAUDE_PARITY"] == "1")
        let scanner = ClaudeLogUsageScanner()
        let result = await scanner.scan(now: Date(), pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        for day in scan.series.daily.sorted(by: { $0.date < $1.date }) {
            print("PARITY \(day.date) tokens=\(day.totalTokens) cost=\(day.costUSD.map { String(format: "%.4f", $0) } ?? "nil")")
        }
        if !scan.unknownModelsByDay.isEmpty {
            print("PARITY unknown models: \(scan.unknownModelsByDay)")
        }
    }

    // MARK: - Cowork session roots

    func testScanSumsTerminalAndCoworkLogs() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "project-a/terminal.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                    messageID: "msg-terminal", requestID: "req-terminal"
                )
            ],
            coworkSessions: [
                "group-1/sub-1/local_a": [
                    "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 10, output: 5, costUSD: 0.05,
                        messageID: "msg-cowork", requestID: "req-cowork"
                    )
                ],
                "group-1/sub-1/agent/local_ditto_a": [
                    "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 2, output: 3, costUSD: 0.01,
                        messageID: "msg-ditto", requestID: "req-ditto"
                    )
                ]
            ]
        )
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 170)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.31, accuracy: 1e-9)
    }

    func testScanFindsCoworkLogsWithoutTerminalClaudeHome() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(coworkSessions: [
            "group-1/sub-1/local_a": [
                "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5, costUSD: 0.05
                )
            ]
        ])
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 15)
    }

    func testScanDeduplicatesReplaysAcrossTerminalAndCoworkLogs() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "project-a/parent.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                    messageID: "msg-shared", requestID: "req-parent", isSidechain: false
                )
            ],
            coworkSessions: [
                "group-1/sub-1/local_a": [
                    "workspace/replay.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 90_000, output: 10, costUSD: 9.99,
                        messageID: "msg-shared", requestID: "req-replay", isSidechain: true
                    )
                ]
            ]
        )
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 150)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)
    }

    func testScanAcceptsProjectsDirItselfInConfigDir() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5, costUSD: 0.01
            )
        ])
        // ccusage accepts `CLAUDE_CONFIG_DIR` pointing at the `projects/` dir itself.
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.appendingPathComponent("projects").path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 15)
    }

    func testScanFollowsSymlinkedProjectsDir() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        // The real logs live outside the config dir (e.g. a externally sync-ed folder) and
        // `~/.claude/projects` is a symlink to them. Root discovery accepted this layout
        // (`fileExists` follows symlinks) but enumeration used to come back empty, so the spend
        // tiles silently under-counted to just the Cowork logs.
        let real = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 100, output: 50, costUSD: 0.25
            )
        ])
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-symlink-home-\(UUID().uuidString)", isDirectory: true)
        let configDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: configDir.appendingPathComponent("projects"),
            withDestinationURL: real.appendingPathComponent("projects")
        )
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 150)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)
    }
}
