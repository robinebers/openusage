import XCTest
@testable import OpenUsage

/// The SQLite scanner: unions `opencode*.db` files, sums all-provider usage for the tiles/trend, and
/// derives Go-only windows for the meters. Fed a stub `SQLiteAccessing` that returns crafted
/// `json_group_array` payloads keyed by path.
final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(
        _ iso: String,
        _ cost: String,
        _ tokens: Int,
        _ model: String,
        _ provider: String,
        input: Int? = nil,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        id: String? = nil,
        completed: Bool = true
    ) -> String {
        let messageID = id ?? "\(provider)-\(model)-\(epochMs(iso))-\(cost)"
        return "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\",\(input ?? tokens),\(cacheRead),\(cacheWrite),\(output),\(reasoning),\"\(messageID)\",\(completed ? 1 : 0)]"
    }

    private func pricing(_ entries: [String: ModelRates]) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: entries),
            secondary: PricingCatalog()
        )
    }

    private func rates(input: Double, output: Double, cacheRead: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: input,
            cacheReadPerMillion: cacheRead
        )
    }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),  // today, go, in session
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),      // today, zen
            row("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),// yesterday, go
            "\"garbage\""                                                             // non-array → skipped
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + row("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = FakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedSeriesUnionsDatabasesAndSkipsGarbage() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 plus Zen 1 = 10; garbage drops.
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 1000 + 500 + 2000 + 800
    }

    func testSessionSumsOnlyGoAcrossDatabases() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        // Session window (last 5h) contains the two go rows (11:00 = 2.0, 09:00 = 4.0); the Zen row at
        // 10:00 is excluded from the Go cap even though it counts toward combined spend.
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 6.0, accuracy: 0.0001)
    }

    func testZenOnlyUsageHasNoGoWindows() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows) // no Go footprint → no empty cap meters
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = OpenCodeUsageScanner(sqlite: FakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertNil(scan.goWindows)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        // Every DB locked/corrupt → the refresh has no data source; an empty "success" would render
        // authoritative-looking $0 meters (regression for the silent-empty-scan bug).
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(failing: ["/oc/opencode.db", "/oc/opencode-next.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testUnreadableDataDirectoryThrowsInsteadOfNil() async {
        // The data dir exists but can't be enumerated → broken access, not "never used OpenCode".
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testHasUsageProbeIncludesExternalProvider() {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "0", 500, "gpt-5.5", "openai") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasUsage())
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        // A corrupt token count over Int.max must clamp (to 1e15), not trap the Int(Double) conversion.
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\",1e19,0,0,0,0,\"huge\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    func testStaleGoAnchorWithoutRecentSpendOrKeyHasNoGoWindows() async throws {
        // Old opencode-go usage left an anchor, but there's no recent Go spend and no auth key: the caps
        // (and the "Go" badge) must NOT come back for a lapsed/Zen-only user.
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now, hasGoKey: false) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows)
    }

    func testGoKeyShowsWindowsEvenWithoutRecentSpend() async throws {
        // Logged into Go but idle in-window → still show the caps at $0, using the anchor for the month.
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now, hasGoKey: true) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 0, accuracy: 0.0001)
    }

    func testOpenAIOAuthTokensAreEstimatedThroughSharedPricing() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 150, "gpt-test", "openai",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["openai/gpt-test": rates(input: 2, output: 10, cacheRead: 0.2)])
        guard let scan = try await scanner.scan(now: now, pricing: modelPricing) else {
            return XCTFail("expected a scan")
        }

        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 150)
        // input 100*$2/M + cache 20*$0.20/M + (output 20 + reasoning 10)*$10/M
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 0.000504, accuracy: 0.0000001)
        XCTAssertEqual(scan.logScan.modelUsage?.daily.first?.models.first?.model, "openai/gpt-test")
    }

    func testGPT56OAuthAbove272KUsesWholeRequestLongContextPricing() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 331_202, "gpt-5.6-sol", "openai",
            input: 330_335, output: 671, reasoning: 196
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let result = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 331_202)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 3.342365, accuracy: 0.0000001)
        XCTAssertEqual(scan.logScan.modelUsage?.daily.first?.models.first?.model, "openai/gpt-5.6-sol")
        XCTAssertTrue(scan.logScan.unknownModelsByDay.isEmpty)
    }

    func testOpenCodeModelAndProviderSpellingsNormalizeBeforePricing() async throws {
        let db = "[" + [
            row("2026-07-12T10:00:00.000Z", "0", 1_000_000, "claude-sonnet-4.5", "github-copilot"),
            row("2026-07-12T09:00:00.000Z", "0", 1_000_000, "k2p6", "kimi-for-coding"),
            row("2026-07-12T08:00:00.000Z", "0", 1_000_000, "gemini-3-pro-high", "google")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing([
            "github_copilot/claude-sonnet-4-5": rates(input: 2, output: 10, cacheRead: 0.2),
            "kimi-k2.6": rates(input: 3, output: 10, cacheRead: 0.3),
            "gemini-3-pro-preview": rates(input: 4, output: 10, cacheRead: 0.4)
        ])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 3_000_000)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 9, accuracy: 0.0001)
        XCTAssertTrue(scan.logScan.unknownModelsByDay.isEmpty)
    }

    func testRawQualifiedPriceWinsOverNormalizedCandidate() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 1_000_000, "claude-sonnet-4.5", "github-copilot"
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing([
            "github-copilot/claude-sonnet-4.5": rates(input: 1, output: 10, cacheRead: 0.1),
            "github_copilot/claude-sonnet-4-5": rates(input: 99, output: 99, cacheRead: 99)
        ])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 1, accuracy: 0.0001)
    }

    func testQualifiedFuzzyMatchCannotShadowBareExactPrice() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 1_000_000, "gpt-5", "openai",
            input: 1_000_000
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing([
            "gpt-5": rates(input: 2, output: 10, cacheRead: 0.2),
            "openrouter/openai/gpt-5-codex": rates(input: 99, output: 99, cacheRead: 99)
        ])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 2, accuracy: 0.0001)
    }

    func testPositiveExternalRecordedCostWinsOverPricing() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "0.588", 500, "zai-org/GLM-5.2", "huggingface") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["zai-org/GLM-5.2": rates(input: 99, output: 99, cacheRead: 99)])
        guard let scan = try await scanner.scan(now: now, pricing: modelPricing) else {
            return XCTFail("expected a scan")
        }

        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 0.588, accuracy: 0.0001)
    }

    func testUnknownExternalModelExcludesTokensAndWarns() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "0", 321, "private-model", "openai") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now, pricing: .empty) else {
            return XCTFail("expected a scan")
        }

        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertEqual(scan.logScan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.logScan.unknownModelsByDay["2026-07-12"], ["openai/private-model"])
        XCTAssertEqual(scan.warning, "OpenCode couldn't price usage for: openai/private-model.")
    }

    func testNegativeExternalRecordedCostIsExcludedInsteadOfEstimated() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "-1", 100, "gpt-test", "openai",
            input: 100
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["openai/gpt-test": rates(input: 99, output: 99, cacheRead: 99)])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)

        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertEqual(scan.logScan.unknownModelsByDay["2026-07-12"], ["openai/gpt-test"])
        XCTAssertEqual(
            scan.warning,
            "Some completed OpenCode messages have invalid cost data. Affected usage is excluded from totals."
        )
    }

    func testGoWindowsExcludeExternalEstimatedCost() async throws {
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2", 100, "glm", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "0", 1_000_000, "gpt-test", "openai")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["gpt-test": rates(input: 10, output: 10, cacheRead: 1)])
        guard let scan = try await scanner.scan(now: now, pricing: modelPricing) else {
            return XCTFail("expected a scan")
        }

        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 2, accuracy: 0.0001)
        XCTAssertGreaterThan(scan.logScan.series.daily.first?.costUSD ?? 0, 2)
    }

    func testDuplicateMessageIDsAcrossDatabasesCountOnce() async throws {
        let stale = row("2026-07-12T09:00:00.000Z", "1", 100, "gpt-5.5", "opencode", id: "msg-shared")
        let completed = row("2026-07-12T10:00:00.000Z", "2", 500, "gpt-5.5", "opencode", id: "msg-shared")
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[\(stale)]", "/oc/opencode-next.db": "[\(completed)]"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 500)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 2, accuracy: 0.0001)
    }

    func testInProgressDuplicateCannotShadowCompletedMessage() async throws {
        let completed = row(
            "2026-07-12T09:00:00.000Z", "2", 500, "gpt-5.5", "opencode",
            id: "msg-shared"
        )
        let newerInProgress = row(
            "2026-07-12T10:00:00.000Z", "0", 700, "gpt-5.5", "opencode",
            id: "msg-shared", completed: false
        )
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: [
                "/oc/opencode.db": "[\(completed)]",
                "/oc/opencode-next.db": "[\(newerInProgress)]"
            ]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )

        let result = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 500)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD ?? -1, 2, accuracy: 0.0001)
    }

    func testComponentBucketsOverrideInconsistentProviderTotal() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 999, "gpt-test", "openai",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["openai/gpt-test": rates(input: 2, output: 10, cacheRead: 0.2)])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 150)
    }

    func testTotalOnlyExternalRecordIsExcludedWhenItCannotBePriced() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 999, "gpt-test", "openai", input: 0
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let modelPricing = pricing(["openai/gpt-test": rates(input: 2, output: 10, cacheRead: 0.2)])
        let result = try await scanner.scan(now: now, pricing: modelPricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertEqual(scan.logScan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.logScan.unknownModelsByDay["2026-07-12"], ["openai/gpt-test"])
    }

    func testMissingHostedCostWarnsExcludesTokensAndSuppressesGoWindows() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "null", 100, "glm", "opencode-go") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let result = try await scanner.scan(now: now, hasGoKey: true)
        let scan = try XCTUnwrap(result)
        XCTAssertNotNil(scan.warning)
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertEqual(scan.logScan.unknownModelsByDay["2026-07-12"], ["glm"])
        XCTAssertNil(scan.goWindows)
    }

    func testInvalidZenCostDoesNotSuppressGoWindowsOrClaimItDoes() async throws {
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2", 100, "glm", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "null", 100, "zen-model", "opencode")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )

        let result = try await scanner.scan(now: now, hasGoKey: true)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.warning, "Some completed OpenCode messages have invalid cost data. Affected usage is excluded from totals.")
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 100)
    }

    func testHistoricalInvalidGoCostOutsideActiveWindowsKeepsCurrentMeters() async throws {
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2", 100, "glm", "opencode-go"),
            row("2026-06-20T10:00:00.000Z", "null", 100, "old-glm", "opencode-go")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )

        let result = try await scanner.scan(now: now, hasGoKey: true)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(
            scan.warning,
            "Some completed OpenCode messages have invalid cost data. Affected usage is excluded from totals."
        )
    }

    func testZeroTokenHostedPlaceholderDoesNotSuppressGoWindows() async throws {
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2", 100, "glm", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "null", 0, "glm", "opencode-go")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )

        let result = try await scanner.scan(now: now, hasGoKey: true)
        let scan = try XCTUnwrap(result)
        XCTAssertNil(scan.warning)
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 2, accuracy: 0.0001)
    }

    func testInProgressAssistantWithOpenCodesInitialZeroCostIsIgnored() async throws {
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 100, "glm", "opencode-go", completed: false
        ) + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        let result = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertNil(scan.goWindows)
    }

    func testDataSQLDoesNotFilterExternalProviderIDs() {
        let sql = OpenCodeUsageDatabaseReader.dataSQL(cutoffMs: 123)
        XCTAssertFalse(sql.contains("providerID') IN"))
        XCTAssertTrue(sql.contains("$.tokens.cache.read"))
        XCTAssertTrue(sql.contains("$.tokens.reasoning"))
        XCTAssertTrue(sql.contains("time_created >="))
        XCTAssertTrue(sql.contains("$.finish"))
    }
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchors: [String: String]
    var failing: Set<String>

    init(data: [String: String] = [:], anchors: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.anchors = anchors
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchors[path] }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
