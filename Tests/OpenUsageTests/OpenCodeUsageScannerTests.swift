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

    func testSQLUnionsBothMessageTablesWithOpenCode2Shapes() {
        let sql = OpenCodeUsageScanner.dataSQL(cutoffMs: 123)
        XCTAssertTrue(sql.contains("FROM message"), sql)
        XCTAssertTrue(sql.contains("FROM session_message"), sql)
        XCTAssertTrue(sql.contains("UNION ALL"), sql)
        XCTAssertTrue(sql.contains("json_extract(data,'$.model.providerID')"), sql)
        XCTAssertTrue(sql.contains("json_extract(data,'$.tokens.cache.write')"), sql)
        XCTAssertTrue(sql.contains("type = 'compaction' AND json_extract(data,'$.status') = 'completed'"), sql)
        XCTAssertTrue(OpenCodeUsageScanner.probeSQL().contains("FROM session_message"))
    }

    func testSingleTableDatabasesNameOnlyTheirTable() async throws {
        let db = "[" + openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "deepseek-v4-pro", "opencode-go") + "]"
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": db], tables: ["/oc/opencode.db": "session_message"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 2.0, accuracy: 0.0001)
        let sql = try XCTUnwrap(sqlite.lastDataSQL)
        XCTAssertFalse(sql.contains("FROM message"), sql)
        XCTAssertFalse(sql.contains("UNION ALL"), sql)

        let v1 = OpenCodeUsageScanner.dataSQL(cutoffMs: 123, tables: .v1)
        XCTAssertFalse(v1.contains("session_message"), v1)
        XCTAssertFalse(v1.contains("compaction"), v1)
    }

    func testDatabaseWithoutMessageTablesDoesNotVote() async throws {
        let sqlite = OpenCodeFakeSQLite(failing: ["/oc/opencode-next.db"], tables: ["/oc/opencode.db": ""])
        let failing = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
        do {
            _ = try await failing.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }

        let empty = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(tables: ["/oc/opencode.db": ""]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await empty.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertFalse(empty.hasHostedUsage())
    }

    /// The generated SQL against a real OpenCode 2 database that still holds the legacy table. Row
    /// shapes follow OpenCode v2.0.20: `packages/schema/src/session-message.ts` (`CompactionCompleted`
    /// carries `model`, `cost`, `tokens`; `CompactionRunning` has none) and
    /// `packages/core/src/session/message-updater.ts` (`session.compaction.ended` writes them). The
    /// running row is given usage anyway to prove the status filter, not the missing fields, drops it.
    func testRealOpenCode2DatabaseCountsEachMessageOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("opencode.db").path
        let t = epochMs("2026-07-12T10:00:00.000Z")
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: path, sql: """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
              time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT, value TEXT,
              connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER, time_updated INTEGER);
            INSERT INTO message VALUES ('m1','s',\(t),\(t),
              '{"role":"assistant","providerID":"opencode-go","modelID":"glm-5.2","cost":2,"tokens":{"total":500}}');
            INSERT INTO session_message VALUES ('m1','s','assistant',1,\(t),\(t),
              '{"model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":2,"tokens":{"input":400,"output":100}}');
            INSERT INTO session_message VALUES ('m2','s','assistant',2,\(t),\(t),
              '{"model":{"id":"gpt-5.5","providerID":"opencode"},"cost":1,"tokens":{"input":100,"output":50,"reasoning":25,"cache":{"read":20,"write":5}}}');
            INSERT INTO session_message VALUES ('m3','s','compaction',3,\(t),\(t),
              '{"status":"completed","reason":"auto","summary":"s","recent":"r","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":0.5,"tokens":{"input":100}}');
            INSERT INTO session_message VALUES ('m4','s','compaction',4,\(t),\(t),
              '{"status":"running","reason":"auto","summary":"s","recent":"r","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":9,"tokens":{"input":1}}');
            INSERT INTO session_message VALUES ('m5','s','assistant',5,\(t),\(t),
              '{"model":{"id":"gpt-5.5","providerID":"openai"},"cost":7,"tokens":{"input":1}}');
            INSERT INTO credential VALUES ('c1','opencode-go','default','{"type":"key","key":"oc_sk_test"}',NULL,NULL,1,\(t),\(t));
            """)

        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { [path] })
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 3.5, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 800)
        XCTAssertTrue(scanner.hasHostedUsage())

        let store = openCodeAuthStore(
            files: FakeFiles(["/oc/auth.json": #"{"opencode-go":{"key":"sk-stale"}}"#]),
            sqlite: sqlite,
            databasePaths: [path]
        )
        XCTAssertEqual(try store.goAPIKey(), "oc_sk_test")
    }

    func testMigratedCopiesAreCountedOnce() async throws {
        let copy = openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 500, "glm-5.2", "opencode-go", id: "msg-same")
        let other = openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 300, "gpt-5.5", "opencode", id: "msg-other")
        let noID = openCodeRow("2026-07-12T09:00:00.000Z", "0.5", 100, "gpt-5.5", "opencode")
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[" + [copy, copy, other, noID, noID].joined(separator: ",") + "]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 1000)
    }
}

/// One `[time_created, cost, tokens, model, provider]` row in the `json_group_array` shape both
/// OpenCode test suites feed the stub.
func openCodeRow(
    _ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String, id: String? = nil
) -> String {
    let epochMs = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    let idField = id.map { ",\"\($0)\"" } ?? ""
    return "[\(epochMs),\(cost),\(tokens),\"\(model)\",\"\(provider)\"\(idField)]"
}

/// An auth store rooted at `/oc` with no real filesystem or sqlite3 access. Shared by every OpenCode
/// and Codex test that needs one.
func openCodeAuthStore(
    files: TextFileAccessing = FakeFiles(),
    sqlite: SQLiteAccessing = OpenCodeFakeSQLite(),
    databasePaths: [String] = []
) -> OpenCodeAuthStore {
    OpenCodeAuthStore(
        files: files,
        environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
        homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
        sqlite: sqlite,
        databasePaths: { databasePaths }
    )
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
/// Shared by the OpenCode scanner and provider tests. `tables` holds each database's
/// `group_concat(name)` probe output (default: both message tables present). `credentials` holds
/// each OpenCode 2 database's current `openai` row; a database without an entry is OpenCode 1 (no
/// `credential` table), and `""` is a table with no `openai` row. `goKeys` holds each database's
/// current `opencode-go` key (`""` for none); it also implies a `credential` table.
final class OpenCodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var credentials: [String: String]
    var tables: [String: String]
    var credentialTimes: [String: String]
    var goKeys: [String: String]
    var lastDataSQL: String?
    var dataSQL: [String: String] = [:]

    init(
        data: [String: String] = [:],
        failing: Set<String> = [],
        credentials: [String: String] = [:],
        tables: [String: String] = [:],
        credentialTimes: [String: String] = [:],
        goKeys: [String: String] = [:]
    ) {
        self.data = data
        self.failing = failing
        self.credentials = credentials
        self.tables = tables
        self.credentialTimes = credentialTimes
        self.goKeys = goKeys
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql == OpenCodeCodexUsageScanner.messageTablesSQL {
            return tables[path] ?? "message,session_message"
        }
        if sql == OpenCodeAuthStore.credentialSQLCurrentOpenAI {
            guard let raw = credentials[path] else {
                throw SQLiteError.queryFailed("Parse error: no such table: credential")
            }
            // Production SQL returns `[value, time_created]`; tests pass just the credential object.
            return raw.isEmpty ? nil : "[\(raw),\(credentialTimes[path] ?? "0")]"
        }
        if sql == OpenCodeAuthStore.credentialSQLGoKey {
            if let key = goKeys[path] { return key.isEmpty ? nil : key }
            if credentials[path] != nil { return nil }
            throw SQLiteError.queryFailed("Parse error: no such table: credential")
        }
        if sql.contains("json_group_array") {
            lastDataSQL = sql
            dataSQL[path] = sql
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
