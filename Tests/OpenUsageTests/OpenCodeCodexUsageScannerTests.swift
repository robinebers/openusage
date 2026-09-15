import XCTest
@testable import OpenUsage

/// OpenCode's ChatGPT OAuth slice is attributed to Codex, following the same carried-cost-else-price
/// policy as pi. API-key OpenAI traffic must never enter the Codex card.
final class OpenCodeCodexUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gpt-test": ModelRates(
                inputPerMillion: 2,
                outputPerMillion: 10,
                cacheWritePerMillion: 2,
                cacheReadPerMillion: 0.2
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private let codexPricing = ModelPricing(
        supplement: PricingSupplement(
            pricing: [
                "gpt-5.6-sol": ModelRates(
                    inputPerMillion: 5,
                    outputPerMillion: 30,
                    cacheWritePerMillion: 6.25,
                    cacheReadPerMillion: 0.5
                )
            ],
            fastMultipliers: ["gpt-5.6-sol": 2.5]
        ),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    private func scanner(auth: String, rows: String, sqlite: OpenCodeFakeSQLite? = nil) -> OpenCodeCodexUsageScanner {
        let database = sqlite ?? OpenCodeFakeSQLite(data: ["/oc/opencode.db": rows])
        return OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": auth]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: database,
            databasePaths: { ["/oc/opencode.db"] }
        )
    }

    func testOAuthUsageIsPricedAndReturnedForCodex() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)

        let day = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(day.totalTokens, 150)
        // 100*$2/M + 20*$0.20/M + (20+10)*$10/M.
        XCTAssertEqual(day.costUSD ?? -1, 0.000504, accuracy: 0.0000001)
        XCTAssertEqual(scan?.modelUsage?.daily.first?.models.first?.model, "gpt-test")
    }

    func testAPIKeyTrafficIsExcludedBeforeDatabaseRead() async {
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        let scan = await scanner(
            auth: #"{"openai":{"type":"api","key":"sk-openai"}}"#,
            rows: "[]",
            sqlite: sqlite
        ).scan(now: now, pricing: pricing)

        XCTAssertNil(scan)
        XCTAssertNil(sqlite.lastDataSQL)
    }

    func testHistoricAPIKeyRowIsExcludedWhileZeroCostOAuthRowStillCounts() async throws {
        let rows = "[" + [
            row(
                "2026-07-12T10:00:00.000Z", cost: "1", total: 150, model: "gpt-test",
                input: 100, output: 50, id: "historic-api-key"
            ),
            row(
                "2026-07-12T11:00:00.000Z", cost: "0", total: 60, model: "gpt-test",
                input: 50, output: 10, id: "current-oauth"
            )
        ].joined(separator: ",") + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 60)
    }

    func testOAuthUsageUsesCodexLongContextRatesPerRequest() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 310_000, model: "gpt-5.6-sol",
            input: 200_000, cacheRead: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Prompt = 300K, above Codex's 272K threshold. The request uses $10/M input,
        // $1/M cache read, and $45/M output: $2 + $0.10 + $0.45 = $2.55.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 2.55, accuracy: 0.000_001)
    }

    func testOAuthUsageAtCodexLongContextBoundaryKeepsBaseRates() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 282_000, model: "gpt-5.6-sol",
            input: 172_000, cacheRead: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Exactly 272K prompt tokens does not cross the threshold.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.21, accuracy: 0.000_001)
    }

    func testOAuthFastAliasAppliesCodexPriorityMultiplierOnce() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 110_000, model: "gpt-5.6-sol-fast",
            input: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Base cost is $0.80. Codex priority is 2x for Sol, even though the supplement's
        // Cursor-oriented fast multiplier is deliberately 2.5x.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.6, accuracy: 0.000_001)
    }

    func testSeparateInputAndCacheReadBucketsAreEachPricedOnce() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 160_000, model: "gpt-5.6-sol",
            input: 100_000, cacheRead: 50_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // OpenCode already stores disjoint buckets, so the native Codex rule of subtracting cached
        // tokens from input must not be applied here: 100K * $5/M + 50K * $0.50/M + 10K * $30/M.
        // Treating the buckets as native's inclusive input would price only 50K at the input rate.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 0.825, accuracy: 0.000_001)
    }

    func testUnknownOAuthModelIsExcludedAndWarned() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-mystery",
            input: 100, output: 50
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: .empty)

        XCTAssertTrue(try XCTUnwrap(scan).series.daily.isEmpty)
        XCTAssertEqual(scan?.unknownModelsByDay["2026-07-12"], ["gpt-mystery"])
    }

    func testCopiedRowsAcrossChannelDatabasesAreDeduplicatedByMessageID() async throws {
        let duplicate = row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, output: 50, id: "same-message"
        )
        let sqlite = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": "[\(duplicate)]",
            "/oc/opencode-next.db": "[\(duplicate)]"
        ])
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"token"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 150)
    }

    func testQuerySelectsOnlyCompletedOpenAIRows() {
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123)
        // The provider path is coalesced rather than a bare `$.providerID` because OpenCode 2 moved it
        // under `$.model`.
        XCTAssertTrue(
            sql.contains("COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) = 'openai'"),
            sql
        )
        XCTAssertTrue(sql.contains("$.cost') = 0"), sql)
        XCTAssertTrue(sql.contains("$.time.completed"), sql)
        XCTAssertTrue(sql.contains("$.finish"), sql)
        XCTAssertTrue(sql.contains("$.tokens.reasoning"), sql)
    }

    func testQueryCoversV2SessionMessageSchema() {
        // OpenCode 2 moved assistant messages to `session_message` with namespaced model paths;
        // a v1-only query returns zero rows there.
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123)
        XCTAssertTrue(sql.contains("session_message"), sql)
        XCTAssertTrue(sql.contains("type = 'assistant'"), sql)
        XCTAssertTrue(sql.contains("$.model.providerID"), sql)
        // Compaction summaries complete via $.status, not the assistant markers.
        XCTAssertTrue(sql.contains("type = 'compaction'"), sql)
        XCTAssertTrue(sql.contains("json_extract(data,'$.status') = 'completed'"), sql)
    }

    func testCompletedCompactionIsAttributed() async throws {
        // Same shape as any other OAuth row: a completed v2 compaction prices like assistant
        // traffic. File-based OAuth carries no creation time, so no age bound applies here.
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 151000, model: "gpt-test",
            input: 150000, cacheRead: 500, output: 400, reasoning: 100, id: "cmp-1", source: "v2"
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 151000)
    }

    func testV2RowsOlderThanTheOAuthCredentialAreExcluded() async throws {
        // Experimental 1.18.x builds recorded zero cost for paid API-key traffic too, so a v2 row
        // older than the OAuth credential may be paid history rather than subscription usage. v1 rows
        // priced paid traffic correctly and are unaffected by the bound.
        let before = row(
            "2026-07-10T10:00:00.000Z", cost: "0", total: 999, model: "gpt-test",
            input: 900, cacheRead: 50, output: 40, reasoning: 9, id: "old-1", source: "v2"
        )
        let after = row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, cacheRead: 20, output: 20, reasoning: 10, id: "new-1", source: "v2"
        )
        let legacy = row(
            "2026-07-10T09:00:00.000Z", cost: "0", total: 70, model: "gpt-test",
            input: 60, cacheRead: 5, output: 4, reasoning: 1, id: "v1-1"
        )
        let credentialMs = Int(OpenUsageISO8601.date(from: "2026-07-11T12:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let sqlite = OpenCodeFakeSQLite(
            data: ["/oc/opencode.db": "[" + [before, after, legacy].joined(separator: ",") + "]"],
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"a","refresh":"r"}"#],
            credentialTimes: ["/oc/opencode.db": "\(credentialMs)"]
        )
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") },
                sqlite: sqlite,
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        let byDay = Dictionary(
            uniqueKeysWithValues: (scan?.series.daily ?? []).map { ($0.date, $0.totalTokens) }
        )
        XCTAssertEqual(byDay["2026-07-12"], 150)
        XCTAssertEqual(byDay["2026-07-10"], 70)
    }

    func testV2OnlyDatabaseScansWithoutNamingTheMissingTable() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": rows], tables: ["/oc/opencode.db": "0|1"])
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"token"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 150)
        XCTAssertTrue(try XCTUnwrap(sqlite.lastDataSQL).contains("session_message"))
        XCTAssertFalse(try XCTUnwrap(sqlite.lastDataSQL).contains("FROM message"))
    }

    func testVariantSQLSelectsOnlyTheTablesItWasGiven() {
        let v1 = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, tables: .v1)
        XCTAssertTrue(v1.contains("FROM message"), v1)
        XCTAssertFalse(v1.contains("session_message"), v1)

        let v2 = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, tables: .v2)
        XCTAssertTrue(v2.contains("FROM session_message"), v2)
        XCTAssertFalse(v2.contains("FROM message"), v2)
    }

    func testFailingUsableDatabaseReturnsNilWhenSchemaLessSiblingExists() async {
        // The skipped file must not vote — the only usable database failed, so no supplement.
        let sqlite = OpenCodeFakeSQLite(
            failing: ["/oc/opencode-next.db"],
            tables: ["/oc/opencode.db": "0|0", "/oc/opencode-next.db": "1|1"]
        )
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"token"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testAllSchemaLessDatabasesYieldEmptySupplement() async {
        // Nothing had usage to read — an empty supplement, not a missing one.
        let sqlite = OpenCodeFakeSQLite(tables: ["/oc/opencode.db": "0|0"])
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"token"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan?.series.daily.isEmpty ?? false)
    }

    private func row(
        _ iso: String,
        cost: String,
        total: Int,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int,
        reasoning: Int = 0,
        id: String = "message-1",
        source: String? = nil
    ) -> String {
        let milliseconds = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
        let base = "[\(milliseconds),\(cost),\(total),\"\(model)\",\(input),\(cacheRead),\(cacheWrite),\(output),\(reasoning),\"\(id)\""
        // No marker decodes as v1, matching rows produced before the source column existed.
        guard let source else { return base + "]" }
        return base + ",\"\(source)\"]"
    }
}
