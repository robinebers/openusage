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
        XCTAssertTrue(sql.contains("providerID') = 'openai'"), sql)
        XCTAssertTrue(sql.contains("$.cost') = 0"), sql)
        XCTAssertTrue(sql.contains("$.time.completed"), sql)
        XCTAssertTrue(sql.contains("$.finish"), sql)
        XCTAssertTrue(sql.contains("$.tokens.reasoning"), sql)
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
        id: String = "message-1"
    ) -> String {
        let milliseconds = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
        return "[\(milliseconds),\(cost),\(total),\"\(model)\",\(input),\(cacheRead),\(cacheWrite),\(output),\(reasoning),\"\(id)\"]"
    }
}
