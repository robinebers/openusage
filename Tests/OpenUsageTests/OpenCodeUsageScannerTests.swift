import XCTest
@testable import OpenUsage

/// The SQLite scanner: unions `opencode*.db` files and sums combined hosted spend for the tiles/trend.
/// Fed a stub `SQLiteAccessing` that returns crafted `json_group_array` payloads keyed by path.
final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),
            openCodeRow("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),
            openCodeRow("2026-07-12T11:00:00.000Z", "null", 100, "x", "opencode-go"),
            "\"garbage\""
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + openCodeRow("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedHostedSeriesUnionsDatabasesAndSkipsGarbage() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 plus Zen 1 = 10; the null-cost and "garbage" rows are dropped.
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 1000 + 500 + 2000 + 800
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db", "/oc/opencode-next.db"]),
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
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testHasHostedUsageProbe() {
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasHostedUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasHostedUsage())
    }

    func testSQLCutoffMatchesCalendarTileWindow() async throws {
        let now = d("2026-07-12T18:00:00.000Z")
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })
        _ = try await scanner.scan(now: now)

        let tileSinceMs = Int(JSONLScanning.sinceDate(daysBack: 30, now: now).timeIntervalSince1970 * 1000)
        guard let sql = sqlite.lastDataSQL else { return XCTFail("expected a data query") }
        XCTAssertTrue(sql.contains("time_created >= \(tileSinceMs)"), sql)
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    // MARK: - Schema probe

    func testMessageTablesParsing() {
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "1|1"), .all)
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "0|1"), .v2)
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "1|0"), .v1)
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "0|0"), [])
        // Malformed output reads as "no tables" so the caller skips the file rather than querying it.
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "1|1\n"), .all)
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: ""), [])
        XCTAssertEqual(OpenCodePaths.messageTables(fromProbeOutput: "not a probe result"), [])
    }

    func testV2OnlyDatabaseScansWithoutNamingTheMissingTable() async throws {
        // A database written by an early 1.18.x build can hold only `session_message`. Naming the
        // absent `message` table would fail preparation and report the provider as unreadable.
        let db = "[" + openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "deepseek-v4-pro", "opencode-go") + "]"
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": db], tables: ["/oc/opencode.db": "0|1"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })

        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 2.0, accuracy: 0.0001)
        let sql = try XCTUnwrap(sqlite.lastDataSQL)
        XCTAssertTrue(sql.contains("session_message"), sql)
        XCTAssertFalse(sql.contains("FROM message"), sql)
        XCTAssertFalse(sql.contains("UNION ALL"), sql)
    }

    func testV1OnlyDatabaseScansWithoutNamingTheMissingTable() async throws {
        let db = "[" + openCodeRow("2026-07-12T11:00:00.000Z", "3.0", 500, "glm-5.2", "opencode") + "]"
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": db], tables: ["/oc/opencode.db": "1|0"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })

        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 3.0, accuracy: 0.0001)
        let sql = try XCTUnwrap(sqlite.lastDataSQL)
        XCTAssertTrue(sql.contains("FROM message"), sql)
        XCTAssertFalse(sql.contains("session_message"), sql)
    }

    func testDatabaseWithNoMessageTablesIsSkippedNotFatal() async throws {
        // A sibling path still has data, so the empty one must not fail the whole refresh.
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(
                data: ["/oc/opencode-next.db": db2],
                tables: ["/oc/opencode.db": "0|0", "/oc/opencode-next.db": "1|1"]
            ),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testHasHostedUsageSkipsDatabasesWithoutMessageTables() {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"], tables: ["/oc/opencode.db": "0|0"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(scanner.hasHostedUsage())
    }

    func testFailingUsableDatabaseStillThrowsWhenSchemaLessSiblingExists() async {
        // The skipped file must not vote — the only usable database failed, so this must throw.
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(
                failing: ["/oc/opencode-next.db"],
                tables: ["/oc/opencode.db": "0|0", "/oc/opencode-next.db": "1|1"]
            ),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testAllSchemaLessDatabasesYieldEmptyScanNotThrow() async throws {
        // Nothing had usage to read — "No data", not an error.
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(tables: ["/oc/opencode.db": "0|0"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
    }

    func testMigratedCopiesAreCountedOnce() async throws {
        // 2.0.3 copies legacy rows into session_message under their original IDs; the union holds
        // both copies of msg-same, which must total 2.0/500 rather than 4.0/1000.
        let copy = openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 500, "glm-5.2", "opencode-go", id: "msg-same")
        let fresh = openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 300, "gpt-5.5", "opencode", id: "msg-other")
        let db = "[" + [copy, copy, fresh].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 3.0, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 800)
    }

    func testCopiesAcrossChannelDatabasesAreCountedOnce() async throws {
        let copy = openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 500, "glm-5.2", "opencode-go", id: "msg-same")
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: [
                "/oc/opencode.db": "[" + copy + "]",
                "/oc/opencode-next.db": "[" + copy + "]",
            ]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 2.0, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 500)
    }

    func testCompletedCompactionSpendIsCounted() async throws {
        // Compaction summaries carry spend at the same paths; only completed ones count.
        let done = openCodeRow("2026-07-12T11:00:00.000Z", "0.5", 151000, "glm-5.2", "opencode-go", id: "cmp-1")
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[" + done + "]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 0.5, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 151000)
    }

    func testV2SQLIncludesCompletedCompactions() {
        for sql in [OpenCodeUsageScanner.dataSQL(cutoffMs: 123), OpenCodeUsageScanner.probeSQL()] {
            XCTAssertTrue(sql.contains("type = 'compaction'"), sql)
            XCTAssertTrue(sql.contains("json_extract(data,'$.status') = 'completed'"), sql)
        }
        // The v1 table has no compaction rows; its branch stays assistant-only.
        let v1 = OpenCodeUsageScanner.dataSQL(cutoffMs: 123, tables: .v1)
        XCTAssertFalse(v1.contains("compaction"), v1)
    }
}

/// One `[time_created, cost, tokens, model, provider]` row in the `json_group_array` shape both
/// OpenCode test suites feed the stub.
func openCodeRow(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String, id: String? = nil) -> String {
    let epochMs = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    let base = "[\(epochMs),\(cost),\(tokens),\"\(model)\",\"\(provider)\""
    guard let id else { return base + "]" }
    return base + ",\"\(id)\"]"
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
/// Shared by the OpenCode scanner and provider tests.
final class OpenCodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var credentials: [String: String]
    /// `v1|v2` counts for the `sqlite_master` probe. Absent paths read as `1|1` so suites that don't
    /// care about the schema keep exercising the union they were written against.
    var tables: [String: String]
    /// `time_created` answers for the credential-table time lookup, keyed by path.
    var credentialTimes: [String: String]
    var lastDataSQL: String?

    init(
        data: [String: String] = [:],
        failing: Set<String> = [],
        credentials: [String: String] = [:],
        tables: [String: String] = [:],
        credentialTimes: [String: String] = [:]
    ) {
        self.data = data
        self.failing = failing
        self.credentials = credentials
        self.tables = tables
        self.credentialTimes = credentialTimes
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        // The scanners ask which message tables exist before building any query, so this answers first.
        if sql.contains("sqlite_master") {
            return tables[path] ?? "1|1"
        }
        // The OAuth-credential time lookup selects time_created from the same table as the value
        // lookup, so it is routed before the generic credential bucket.
        if sql.contains("FROM credential") && sql.contains("time_created") {
            return credentialTimes[path]
        }
        // OpenCode 2 credential-table lookups have their own payload bucket so the auth fallback
        // path is testable without mixing usage rows and credential rows.
        if sql.contains("FROM credential") {
            return credentials[path]
        }
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
