import XCTest
@testable import OpenUsage

enum ClaudeLogUsageScannerTestFixtures {
    /// Deterministic fixture pricing: input $10/M, output $20/M, cache write $12.5/M, read $1/M.
    static func pricing() -> ModelPricing {
        ModelPricing(
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
    }
}

/// Line parsing, deduplication, and day aggregation for the native Claude log scanner — the
/// dedup/validity fixtures are ported from ccusage's Claude adapter tests so the two agree on
/// what counts.
final class ClaudeLogUsageScannerTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    let pricing = ClaudeLogUsageScannerTestFixtures.pricing()

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

}
