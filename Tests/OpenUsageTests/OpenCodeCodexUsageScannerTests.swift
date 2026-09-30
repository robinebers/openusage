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

    private let oauthAuth = #"{"openai":{"type":"oauth","access":"token"}}"#

    private func fileOAuthStore(_ auth: String) -> OpenCodeAuthStore {
        openCodeAuthStore(files: FakeFiles(["/oc/auth.json": auth]))
    }

    private func scanner(auth: String, rows: String, sqlite: OpenCodeFakeSQLite? = nil) -> OpenCodeCodexUsageScanner {
        let database = sqlite ?? OpenCodeFakeSQLite(data: ["/oc/opencode.db": rows])
        return OpenCodeCodexUsageScanner(
            authStore: fileOAuthStore(auth),
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
            authStore: fileOAuthStore(oauthAuth),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 150)
    }

    /// Two channel databases with their own OpenCode 2 credentials; the same fake serves both the
    /// scanner and its auth store so per-database credentials and rows line up.
    private func channelScanner(
        credentials: [String: String],
        credentialTimes: [String: String] = [:],
        rows: [String: String]
    ) -> (OpenCodeCodexUsageScanner, OpenCodeFakeSQLite) {
        let sqlite = OpenCodeFakeSQLite(data: rows, credentials: credentials, credentialTimes: credentialTimes)
        let scanner = OpenCodeCodexUsageScanner(
            authStore: openCodeAuthStore(sqlite: sqlite),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode-next.db", "/oc/opencode.db"] }
        )
        return (scanner, sqlite)
    }

    func testEachChannelDatabaseIsGatedByItsOwnCredential() async throws {
        // Stable holds a newer API key while preview is still on OAuth: preview usage counts, stable
        // usage does not — regardless of which credential was touched last.
        let (scanner, _) = channelScanner(
            credentials: [
                "/oc/opencode-next.db": #"{"type":"oauth","access":"live"}"#,
                "/oc/opencode.db": #"{"type":"key","key":"sk-x"}"#
            ],
            rows: [
                "/oc/opencode-next.db": "[" + row(
                    "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
                    input: 100, output: 50, id: "preview-oauth"
                ) + "]",
                "/oc/opencode.db": "[" + row(
                    "2026-07-12T11:00:00.000Z", cost: "0", total: 900, model: "gpt-test",
                    input: 600, output: 300, id: "stable-api-key"
                ) + "]"
            ]
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 150)
    }

    func testEachOAuthChannelUsesItsOwnLoginTimeAsTheV2Bound() async {
        // Preview logged in later than stable. Stable's older rows must stay bounded by stable's own
        // login, not cut off by preview's.
        let stableLogin = Int(OpenUsageISO8601.date(from: "2026-07-01T00:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let previewLogin = Int(OpenUsageISO8601.date(from: "2026-07-10T00:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let (scanner, sqlite) = channelScanner(
            credentials: [
                "/oc/opencode-next.db": #"{"type":"oauth","access":"preview"}"#,
                "/oc/opencode.db": #"{"type":"oauth","access":"stable"}"#
            ],
            credentialTimes: [
                "/oc/opencode-next.db": String(previewLogin),
                "/oc/opencode.db": String(stableLogin)
            ],
            rows: ["/oc/opencode-next.db": "[]", "/oc/opencode.db": "[]"]
        )

        _ = await scanner.scan(now: now, pricing: pricing)
        let previewSQL = sqlite.dataSQL["/oc/opencode-next.db"] ?? ""
        let stableSQL = sqlite.dataSQL["/oc/opencode.db"] ?? ""
        XCTAssertTrue(previewSQL.contains(">= \(previewLogin)"), previewSQL)
        XCTAssertFalse(previewSQL.contains(">= \(stableLogin)"), previewSQL)
        XCTAssertTrue(stableSQL.contains(">= \(stableLogin)"), stableSQL)
        XCTAssertFalse(stableSQL.contains(">= \(previewLogin)"), stableSQL)
    }

    func testLoggedOutV2DatabaseIsSkippedWhileAuthFileStillHoldsOAuth() async {
        // OpenCode 2 logout empties the credential table but leaves the imported auth.json behind;
        // that file must not authorize the database's rows.
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"], credentials: ["/oc/opencode.db": ""])
        let scanner = OpenCodeCodexUsageScanner(
            authStore: openCodeAuthStore(files: FakeFiles(["/oc/auth.json": oauthAuth]), sqlite: sqlite),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
        XCTAssertNil(sqlite.lastDataSQL)
    }

    func testQuerySelectsOnlyCompletedOpenAIRows() {
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123)
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
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123)
        XCTAssertTrue(sql.contains("session_message"), sql)
        XCTAssertTrue(sql.contains("type = 'assistant'"), sql)
        XCTAssertTrue(sql.contains("$.model.providerID"), sql)
        XCTAssertTrue(sql.contains("type = 'compaction'"), sql)
        XCTAssertTrue(sql.contains("json_extract(data,'$.status') = 'completed'"), sql)
    }

    func testCompletedCompactionIsAttributed() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 151_000, model: "gpt-test",
            input: 100_000, output: 51_000, id: "compaction-1"
        ) + "]"
        let scan = await scanner(auth: oauthAuth, rows: rows).scan(now: now, pricing: pricing)

        let day = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(day.totalTokens, 151_000)
        // 100K*$2/M + 51K*$10/M.
        XCTAssertEqual(day.costUSD ?? -1, 0.71, accuracy: 0.0000001)
    }

    func testOAuthCreationTimeBoundsOnlyTheV2Branch() {
        // Zero-cost v2 rows older than the login may be paid 1.18.x history; v1 rows priced paid
        // traffic correctly. The bound sits inside the v2 branch, so a migrated v1 twin of an
        // excluded row still reaches the union and dedup.
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, oauthSinceMs: 456)
        let v1 = sql[sql.range(of: "FROM message")!.lowerBound..<sql.range(of: "UNION ALL")!.lowerBound]
        let v2 = sql[sql.range(of: "FROM session_message")!.lowerBound...]
        XCTAssertFalse(v1.contains(">= 456"), String(v1))
        XCTAssertTrue(v2.contains("COALESCE(json_extract(data,'$.time.completed'),time_created) >= 456"), String(v2))
        XCTAssertFalse(OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123).contains(">= 456"))
    }

    func testScanPassesTheCredentialCreationTimeIntoTheQuery() async {
        let credentialAt = OpenUsageISO8601.date(from: "2026-07-11T12:00:00.000Z")!
        let sinceMs = Int(credentialAt.timeIntervalSince1970 * 1000)
        let sqlite = OpenCodeFakeSQLite(
            data: ["/oc/opencode.db": "[]"],
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"token"}"#],
            credentialTimes: ["/oc/opencode.db": String(sinceMs)]
        )
        let databaseBacked = OpenCodeCodexUsageScanner(
            authStore: openCodeAuthStore(sqlite: sqlite),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )
        _ = await databaseBacked.scan(now: now, pricing: pricing)
        XCTAssertTrue(sqlite.lastDataSQL?.contains(">= \(sinceMs)") == true, sqlite.lastDataSQL ?? "nil")

        // A file-based credential carries no timestamp, so v2 rows are unbounded.
        let fileBacked = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        _ = await scanner(auth: oauthAuth, rows: "[]", sqlite: fileBacked).scan(now: now, pricing: pricing)
        XCTAssertFalse(fileBacked.lastDataSQL?.contains(">= \(sinceMs)") == true, fileBacked.lastDataSQL ?? "nil")
    }

    func testV2OnlyDatabaseScansWithoutNamingTheMissingTable() async {
        let sqlite = OpenCodeFakeSQLite(
            data: ["/oc/opencode.db": "[]"],
            tables: ["/oc/opencode.db": "session_message"]
        )
        _ = await scanner(auth: oauthAuth, rows: "[]", sqlite: sqlite).scan(now: now, pricing: pricing)

        guard let sql = sqlite.lastDataSQL else { return XCTFail("expected a data query") }
        XCTAssertTrue(sql.contains("session_message"), sql)
        XCTAssertFalse(sql.contains("FROM message"), sql)
    }

    func testVariantSQLSelectsOnlyTheTablesItWasGiven() {
        let v1 = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, tables: .v1)
        XCTAssertTrue(v1.contains("FROM message"), v1)
        XCTAssertFalse(v1.contains("session_message"), v1)

        let v2 = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, tables: .v2)
        XCTAssertTrue(v2.contains("session_message"), v2)
        XCTAssertFalse(v2.contains("FROM message"), v2)
    }

    func testFailingUsableDatabaseReturnsNilWhenSchemaLessSiblingExists() async {
        let sqlite = OpenCodeFakeSQLite(
            failing: ["/oc/opencode-next.db"],
            tables: ["/oc/opencode.db": ""]
        )
        let scanner = OpenCodeCodexUsageScanner(
            authStore: fileOAuthStore(oauthAuth),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testAllSchemaLessDatabasesYieldEmptySupplement() async {
        let sqlite = OpenCodeFakeSQLite(tables: ["/oc/opencode.db": ""])
        guard let scan = await scanner(auth: oauthAuth, rows: "[]", sqlite: sqlite).scan(now: now, pricing: pricing) else {
            return XCTFail("expected a scan")
        }
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    func testMessageTablesProbeParsing() throws {
        func probe(_ output: String) throws -> OpenCodeCodexUsageScanner.MessageTables? {
            try OpenCodeCodexUsageScanner.messageTables(
                in: "/oc/opencode.db", sqlite: OpenCodeFakeSQLite(tables: ["/oc/opencode.db": output])
            )
        }
        XCTAssertEqual(try probe("message,session_message"), .all)
        XCTAssertEqual(try probe("session_message"), .v2)
        XCTAssertEqual(try probe("message"), .v1)
        XCTAssertEqual(try probe("message, session_message\n"), .all)
        XCTAssertNil(try probe(""))
        XCTAssertNil(try probe("not a probe result"))
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
