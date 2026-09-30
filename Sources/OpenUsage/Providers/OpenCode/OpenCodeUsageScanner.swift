import Foundation

/// The result of a local OpenCode scan: the combined-hosted daily series for the spend tiles + trend.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
}

/// Reads OpenCode's local SQLite logs (`~/.local/share/opencode/opencode*.db`, all release channels)
/// for the spend tiles and usage trend. Cookie-free: the per-message `cost` OpenCode writes for its
/// own hosted gateways is authoritative (Zen models aren't in our pricing snapshots), so it is summed
/// directly rather than re-priced. Go plan windows come from the usage API, not this scan.
///
/// A `Sendable` struct (like the Grok scanner), `async` and nonisolated, so the SQLite reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct OpenCodeUsageScanner: Sendable {
    /// The OpenCode-hosted providerIDs we track: the Go subscription and the Zen pay-as-you-go gateway.
    /// Both write an authoritative `cost`; other (BYO-key) providerIDs log `cost: 0` and are out of scope.
    static let hostedProviderIDs = ["opencode-go", "opencode"]

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no OpenCode database at all;
    /// a present-but-empty database yields an empty scan (idle tiles collapse to "No data" via
    /// `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none could be read.
    func scan(now: Date, daysBack: Int = 30) async throws -> OpenCodeUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The data directory exists but couldn't be enumerated — same failure class as unreadable
            // databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        // Same calendar bound the tiles/trend use. A wall-clock `now - daysBack×86400` cutoff sits
        // later the same day, so morning rows on the oldest day never leave SQLite.
        let tileSince = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(tileSince.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            do {
                // A database with no message tables has no usage to read and does not vote on failure.
                guard let tables = try OpenCodeCodexUsageScanner.messageTables(in: path, sqlite: sqlite) else { continue }
                checked.insert(path)
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs, tables: tables)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                checked.insert(path)
                failures[path] = error.localizedDescription
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if !checked.isEmpty && failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        var accumulator = DailyUsageAccumulator()
        // OpenCode 2 copies legacy `message` rows into `session_message` under their original IDs and
        // keeps both tables, so the union can hold two copies of one message.
        var seenIDs: Set<String> = []
        for row in rows {
            if let id = row.id, !seenIDs.insert(id).inserted { continue }
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model
            )
        }
        return OpenCodeUsageScan(logScan: accumulator.build())
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold at least one hosted
    /// assistant row with a numeric cost? Read-only, no network. Failures are logged (this runs only
    /// during first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// data directory counts as an OpenCode footprint so `refresh()` gets to surface the real error.
    func hasHostedUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                guard let tables = try OpenCodeCodexUsageScanner.messageTables(in: path, sqlite: sqlite) else { continue }
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL(tables: tables)), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var cost: Double
        var tokens: Int
        var model: String
        var id: String?
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, cost, tokensTotal, modelID, providerID, id]`. Rows with a missing timestamp/cost or a
    /// non-string providerID are skipped at this boundary.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let cost = ProviderParse.number(entry[1]), cost >= 0,
                  entry[4] is String
            else { continue }
            // Clamp before the Int conversion so a corrupt, absurdly large token count can't trap
            // (Int(Double) crashes above Int.max). 1e15 is far above any real token total.
            let tokens = Int(min(max(ProviderParse.number(entry[2]) ?? 0, 0), 1e15))
            let model = (entry[3] as? String) ?? ""
            let id = entry.count >= 6 ? (entry[5] as? String)?.nilIfEmpty : nil
            rows.append(Row(ms: ms, cost: cost, tokens: tokens, model: model, id: id))
        }
        return rows
    }

    // MARK: - SQL

    /// SQL literal built from `hostedProviderIDs`, so the tracked list has one source of truth.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    /// OpenCode 1 writes `message` rows with flat `role`/`modelID`/`providerID`; OpenCode 2 writes
    /// `session_message` rows with a `type` column and a nested `$.model`, and its migrated rows carry
    /// token buckets without `$.tokens.total`. Completed compactions carry usage too.
    private static let modelID = "COALESCE(json_extract(data,'$.model.id'), json_extract(data,'$.modelID'))"
    private static let providerID =
        "COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID'))"
    private static let totalTokens = """
        COALESCE(json_extract(data,'$.tokens.total'),
                 COALESCE(json_extract(data,'$.tokens.input'),0)
                 + COALESCE(json_extract(data,'$.tokens.output'),0)
                 + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                 + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                 + COALESCE(json_extract(data,'$.tokens.cache.write'),0))
        """
    private static let v1Role = "json_extract(data,'$.role') = 'assistant'"
    private static let v2Role =
        "(type = 'assistant' OR (type = 'compaction' AND json_extract(data,'$.status') = 'completed'))"

    private static func rowsSQL(table: String, role: String, cutoffMs: Int?) -> String {
        """
        SELECT id, time_created, data FROM \(table)
          WHERE \(cutoffMs.map { "time_created >= \($0)\n            AND " } ?? "")json_valid(data)
            AND \(role)
            AND \(providerID) IN \(providerFilter)
            AND json_type(data,'$.cost') IN ('integer','real')
        """
    }

    private static func source(_ tables: OpenCodeCodexUsageScanner.MessageTables, cutoffMs: Int?) -> String {
        var bodies: [String] = []
        if tables.contains(.v1) { bodies.append(rowsSQL(table: "message", role: v1Role, cutoffMs: cutoffMs)) }
        if tables.contains(.v2) { bodies.append(rowsSQL(table: "session_message", role: v2Role, cutoffMs: cutoffMs)) }
        return "(\n" + bodies.joined(separator: "\n        UNION ALL\n") + "\n)"
    }

    static func dataSQL(cutoffMs: Int, tables: OpenCodeCodexUsageScanner.MessageTables = .all) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 \(totalTokens),
                 \(modelID),
                 \(providerID),
                 id))
        FROM \(source(tables, cutoffMs: cutoffMs));
        """
    }

    static func probeSQL(tables: OpenCodeCodexUsageScanner.MessageTables = .all) -> String {
        "SELECT 1 FROM \(source(tables, cutoffMs: nil))\nLIMIT 1;"
    }
}
