import XCTest
@testable import OpenUsage

/// The SQLite scanner: unions `~/.zcode/cli/db/*.sqlite` and prices each logged model request into the
/// daily series behind the spend tiles and trend. Fed a stub `SQLiteAccessing` that returns crafted
/// `json_group_array` payloads keyed by path.
final class ZcodeUsageScannerTests: XCTestCase {
    private func date(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(date(iso).timeIntervalSince1970 * 1000) }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    /// Textbook rates: $1 per million in, $4 out, $0.25 cache read — so expected costs read off by hand.
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "glm-5.3": ModelRates(
                inputPerMillion: 1, outputPerMillion: 4,
                cacheWritePerMillion: 1, cacheReadPerMillion: 0.25
            )
        ]),
        secondary: PricingCatalog()
    )

    private func scanner(databasePaths: @escaping @Sendable () throws -> [String]) -> ZcodeUsageScanner {
        ZcodeUsageScanner(sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": validDatabase]),
                          databasePaths: databasePaths)
    }

    /// Two requests today and one yesterday. The first is the real shape of a cache-heavy agent turn:
    /// Zcode folds cache reads into `input_tokens` (see `parseRows`).
    private var validDatabase: String {
        "[" + [
            zcodeRow("2026-07-12T11:00:00.000Z", "glm-5.3", input: 75_212, output: 837, cacheRead: 63_872),
            zcodeRow("2026-07-12T10:00:00.000Z", "glm-5.3", input: 1000, output: 500),
            zcodeRow("2026-07-11T10:00:00.000Z", "glm-5.3", input: 2000, output: 1000),
            zcodeRow("2026-07-12T09:00:00.000Z", "glm-5.3", input: 0, output: 0),
            "[\(epochMs("2026-07-12T09:30:00.000Z"))]",
            "\"garbage\""
        ].joined(separator: ",") + "]"
    }

    func testCacheDeduplicationPricesOnlyUncachedInput() async throws {
        // input 75,212 already contains the 63,872 cache reads, so billed input is 11,340:
        // 11,340×$1 + 63,872×$0.25 + 837×$4 per million = $0.037238
        let scan = try await scanner(databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }).scan(now: now, pricing: pricing)
        guard let today = scan?.series.daily.first(where: { $0.date == "2026-07-12" }) else {
            return XCTFail("expected a today entry")
        }
        XCTAssertEqual(today.totalTokens, 76_049 + 1500) // (75,212 + 837) + (1000 + 500)
        XCTAssertEqual(today.costUSD ?? 0, 0.011_340 + 0.015_968 + 0.003_348 + 0.001 + 0.002, accuracy: 1e-9)
    }

    func testYesterdayIsAggregatedSeparately() async throws {
        let scan = try await scanner(databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }).scan(now: now, pricing: pricing)
        let yesterday = scan?.series.daily.first(where: { $0.date == "2026-07-11" })
        XCTAssertEqual(yesterday?.totalTokens, 3000)
        XCTAssertEqual(yesterday?.costUSD ?? 0, 0.002 + 0.004, accuracy: 1e-9)
    }

    func testCacheWritesAndReadsAreNotCountedTwice() async throws {
        let db = "[" + zcodeRow("2026-07-12T10:00:00.000Z", "glm-5.3",
                                input: 1000, output: 100, cacheRead: 600, cacheWrite: 200) + "]"
        let scanner = ZcodeUsageScanner(sqlite: ZcodeFakeSQLite(data: ["db": db]), databasePaths: { ["db"] })
        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 1100)
        XCTAssertEqual(scan?.series.daily.first?.costUSD ?? 0, 0.00095, accuracy: 1e-9)
    }

    func testActualSQLiteFiltersOldAndZeroTokenRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: path, sql: """
            CREATE TABLE model_usage (
                started_at INTEGER, model_id TEXT, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER);
            INSERT INTO model_usage VALUES
                (\(epochMs("2026-07-12T10:00:00.000Z")), 'glm-5.3', 1000, 100, 600, 200),
                (\(epochMs("2026-07-12T09:00:00.000Z")), 'glm-5.3', 0, 0, 0, 0),
                (\(epochMs("2026-01-01T10:00:00.000Z")), 'glm-5.3', 5000, 1000, 0, 0);
            """)
        let scanner = ZcodeUsageScanner(sqlite: sqlite, databasePaths: { [path] })
        XCTAssertTrue(scanner.hasModelUsage())
        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.count, 1)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 1100)
        XCTAssertEqual(scan?.series.daily.first?.costUSD ?? 0, 0.00095, accuracy: 1e-9)
        XCTAssertEqual(try sqlite.queryValue(path: path, sql: "SELECT COUNT(*) FROM model_usage;"), "3")
    }

    func testZeroTokenRowsAndMalformedPayloadsAreDropped() async throws {
        let scan = try await scanner(databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }).scan(now: now, pricing: pricing)
        // One day entry per used day; the zeroed row contributes nothing and its day never appears.
        XCTAssertEqual(scan?.series.daily.count, 2)
    }

    func testModelBreakdownUsesLoggedModelID() async throws {
        let scan = try await scanner(databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }).scan(now: now, pricing: pricing)
        let today = scan?.modelUsage?.daily.first(where: { $0.date == "2026-07-12" })
        XCTAssertEqual(today?.models.count, 1)
        XCTAssertEqual(today?.models.first?.model, "glm-5.3")
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = ZcodeUsageScanner(sqlite: ZcodeFakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": "[]"]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        guard let scan = try await scanner.scan(now: now, pricing: pricing) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let sqlite = ZcodeFakeSQLite(
            data: ["~/.zcode/cli/db/db.sqlite": validDatabase],
            failing: ["~/.zcode/cli/db/shard.sqlite"]
        )
        let scanner = ZcodeUsageScanner(
            sqlite: sqlite,
            databasePaths: { ["~/.zcode/cli/db/shard.sqlite", "~/.zcode/cli/db/db.sqlite"] }
        )
        guard let scan = try await scanner.scan(now: now, pricing: pricing) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.series.daily.count, 2)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(failing: ["~/.zcode/cli/db/db.sqlite"]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        do {
            _ = try await scanner.scan(now: now, pricing: pricing)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? ZcodeUsageError, .databaseUnreadable)
        }
    }

    func testMalformedQueryResponseIsAnErrorInsteadOfNoData() async {
        let scanner = ZcodeUsageScanner(sqlite: ZcodeFakeSQLite(data: ["db": "invalid JSON"]),
                                        databasePaths: { ["db"] })
        do {
            _ = try await scanner.scan(now: now, pricing: pricing)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? ZcodeUsageError, .databaseUnreadable)
        }
    }

    func testUnreadableDatabaseDirectoryThrowsInsteadOfNil() async {
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now, pricing: pricing)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? ZcodeUsageError, .databaseUnreadable)
        }
    }

    func testUnpriceableModelIsReportedAsUnknownNotZeroCost() async throws {
        let db = "[" + zcodeRow("2026-07-12T10:00:00.000Z", "mystery-model", input: 1000, output: 500) + "]"
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": db]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertTrue(scan?.series.daily.isEmpty ?? false)
        XCTAssertEqual(scan?.unknownModelsByDay["2026-07-12"], ["mystery-model"])
    }

    func testHasModelUsageProbe() {
        let withUsage = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": validDatabase]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        XCTAssertTrue(withUsage.hasModelUsage())

        let empty = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": "[]"]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        XCTAssertFalse(empty.hasModelUsage())
    }

    func testUnreadableDatabaseCountsAsFootprint() {
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(failing: ["~/.zcode/cli/db/db.sqlite"]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        XCTAssertTrue(scanner.hasModelUsage())
    }

    func testSQLCutoffMatchesCalendarTileWindow() async throws {
        let now = date("2026-07-12T18:00:00.000Z")
        let sqlite = ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": "[]"])
        let scanner = ZcodeUsageScanner(sqlite: sqlite, databasePaths: { ["~/.zcode/cli/db/db.sqlite"] })
        _ = try await scanner.scan(now: now, pricing: pricing)

        let expected = Int(JSONLScanning.sinceDate(daysBack: 30, now: now).timeIntervalSince1970 * 1000)
        guard let sql = sqlite.lastDataSQL else { return XCTFail("expected a data query") }
        XCTAssertTrue(sql.contains("started_at >= \(expected)"), sql)
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        let db = "[" + zcodeRow("2026-07-12T10:00:00.000Z", "glm-5.3", input: 75_212, output: 1_000_000_000_000_000_000) + "]"
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": db]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 1_000_000_000_075_212)
    }

    func testBundledSupplementPricesZcodeModelIDs() async throws {
        // The alias coverage this provider depends on: the raw `GLM-5.3-Flash` slug Zcode logs resolves
        // through the shipped supplement (and no price source is needed beyond it).
        let db = "[" + [
            zcodeRow("2026-07-12T10:00:00.000Z", "GLM-5.3-Flash", input: 1_000_000, output: 100_000),
            zcodeRow("2026-07-12T10:00:00.000Z", "GLM-5.3", input: 1_000_000, output: 100_000)
        ].joined(separator: ",") + "]"
        let scanner = ZcodeUsageScanner(
            sqlite: ZcodeFakeSQLite(data: ["~/.zcode/cli/db/db.sqlite": db]),
            databasePaths: { ["~/.zcode/cli/db/db.sqlite"] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertTrue(scan?.unknownModelsByDay.isEmpty ?? false)
        let cost = scan?.series.daily.first?.costUSD ?? 0
        // GLM-5.3-Flash $0.15/$0.50 + GLM-5.3 $1.40/$4.40 per million for 1M in / 100K out.
        XCTAssertEqual(cost, (0.15 + 0.05) + (1.4 + 0.44), accuracy: 1e-6)
    }
}

/// One `[started_at, model_id, input, output, cache_read, cache_creation]` row in the
/// `json_group_array` shape the scanner queries.
func zcodeRow(
    _ iso: String,
    _ model: String,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0
) -> String {
    let epochMs = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    return "[\(epochMs),\"\(model)\",\(input),\(output),\(cacheRead),\(cacheWrite)]"
}

/// Stub returning crafted payloads per database path, classifying the query by SQL shape.
final class ZcodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var lastDataSQL: String?

    init(data: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") {
            lastDataSQL = sql
            return data[path]
        }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
