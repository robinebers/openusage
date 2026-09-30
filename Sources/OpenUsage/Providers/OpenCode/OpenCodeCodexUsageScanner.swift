import Foundation

/// Reads Codex-subscription usage produced inside OpenCode and returns it in the same normalized shape
/// as Codex's native and pi scanners. OpenCode records both ChatGPT OAuth and ordinary OpenAI API-key
/// traffic as `providerID = openai`, so a database's rows are eligible only while that database's
/// current OpenCode credential is explicitly OAuth. This avoids charging API-key traffic to the
/// Codex subscription card.
///
/// Reads both the v1 `message` and v2 `session_message` tables: OpenCode 2 moved assistant messages
/// to the new table, so a v1-only query returns zero rows there.
struct OpenCodeCodexUsageScanner: Sendable {
    private let authStore: OpenCodeAuthStore
    private let sqlite: SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.authStore = authStore
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    /// Best-effort supplementary scan: failures are logged loudly but never hide Codex's live quota
    /// meters or native history. This matches pi's role as an optional local source.
    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "Codex usage database discovery failed: \(error.localizedDescription)")
            return nil
        }
        guard !paths.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var failures: [String: String] = [:]
        var readAny = false
        var anyOAuth = false
        for path in paths {
            do {
                // Each channel database is judged by its own credential: a stable API key must not
                // hide preview OAuth usage, and one channel's login time must not bound another's rows.
                let credential = try authStore.openAICredential(databasePath: path)
                guard credential.isOAuth else { continue }
                anyOAuth = true
                // A database with no message tables has nothing to contribute; skip it rather than let
                // the query fail and drop every other database's rows.
                guard let tables = try Self.messageTables(in: path, sqlite: sqlite) else { continue }
                let oauthSinceMs = credential.since.map { Int($0.timeIntervalSince1970 * 1000) }
                let sql = Self.dataSQL(cutoffMs: cutoffMs, tables: tables, oauthSinceMs: oauthSinceMs)
                if let json = try sqlite.queryValue(path: path, sql: sql) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
                readAny = true
            } catch {
                failures[path] = error.localizedDescription
            }
        }
        // Edge-triggered like the OpenCode card's own scanner: a persistently locked database warns
        // once per new failure, not on every refresh.
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: Set(paths), failingPaths: Set(failures.keys)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "Codex usage query failed for \(path): \(failures[path] ?? "unknown error")"
            )
        }
        // No OAuth channel means nothing to attribute. Databases without message tables never vote:
        // every readable one either succeeded or failed.
        guard anyOAuth, readAny || failures.isEmpty else { return nil }

        var accumulator = DailyUsageAccumulator()
        // Codex pricing depends only on the model slug, and resolving one walks every supplement alias
        // rule. Real histories run to thousands of rows across a handful of models, so resolve once each.
        var preparedByModel: [String: CodexUsagePricing.Prepared?] = [:]
        for row in Self.deduplicated(rows) where row.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: row.timestamp)
            guard let model = row.model.nilIfEmpty else { continue }
            let prepared: CodexUsagePricing.Prepared?
            if let cached = preparedByModel[model] {
                prepared = cached
            } else {
                prepared = CodexUsagePricing.prepare(pricing: pricing, model: model)
                preparedByModel[model] = prepared
            }
            guard let prepared else {
                if row.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            accumulator.add(
                day: day,
                tokens: row.reportedTotalTokens,
                cost: CodexUsagePricing.cost(prepared: prepared, tokens: row.tokens),
                model: model
            )
        }
        return accumulator.build()
    }

    struct Row: Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
    }

    /// Decodes `[completedAt, cost, total, model, input, cacheRead, cacheWrite, output, reasoning, id]`.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 10,
                  let milliseconds = ProviderParse.number(values[0]),
                  // The built-in OpenCode Codex OAuth plugin deliberately sets every model rate to
                  // zero. A positive recorded cost is OpenAI API-key traffic, including historic rows
                  // left behind before a user switched the current credential to OAuth.
                  ProviderParse.number(values[1]) == 0
            else { return nil }
            let input = clampedTokens(values[4])
            let cacheRead = clampedTokens(values[5])
            let cacheWrite = clampedTokens(values[6])
            let output = clampedTokens(values[7])
            let reasoning = clampedTokens(values[8])
            let tokens = TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite,
                cacheRead: cacheRead,
                output: output + reasoning
            )
            return Row(
                id: (values[9] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                model: ((values[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: tokens,
                // OpenCode's own total is only a fallback: the parsed buckets are what gets priced.
                reportedTotalTokens: tokens.totalTokens > 0 ? tokens.totalTokens : clampedTokens(values[2])
            )
        }
    }

    /// OpenCode can copy a session between release-channel databases. Stable message IDs make those
    /// copies safe to union without double counting; rows without an ID remain independent.
    static func deduplicated(_ rows: [Row]) -> [Row] {
        var withoutID: [Row] = []
        var byID: [String: Row] = [:]
        for row in rows {
            guard let id = row.id else {
                withoutID.append(row)
                continue
            }
            guard let existing = byID[id] else {
                byID[id] = row
                continue
            }
            if row.timestamp > existing.timestamp ||
                (row.timestamp == existing.timestamp && row.reportedTotalTokens > existing.reportedTotalTokens) {
                byID[id] = row
            }
        }
        return withoutID + byID.values
    }

    private static func clampedTokens(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }

    /// Which assistant-message tables a database holds. OpenCode 2 creates both and never drops the
    /// legacy one, so most installs have `.all`, but an early 1.18.x build can hold only
    /// `session_message`. Naming a missing table fails statement preparation, which would read as an
    /// unreadable database, so the scanner asks before it queries.
    struct MessageTables: OptionSet, Sendable {
        let rawValue: Int

        /// The legacy `message` table (OpenCode 1).
        static let v1 = MessageTables(rawValue: 1)
        /// The `session_message` table (OpenCode 2).
        static let v2 = MessageTables(rawValue: 2)
        static let all: MessageTables = [.v1, .v2]
    }

    static let messageTablesSQL =
        "SELECT group_concat(name) FROM sqlite_master WHERE type='table' AND name IN ('message','session_message');"

    /// The message tables a database holds, or `nil` when it holds neither (the caller skips it).
    static func messageTables(in path: String, sqlite: SQLiteAccessing) throws -> MessageTables? {
        let names = try sqlite.queryValue(path: path, sql: messageTablesSQL)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var tables: MessageTables = []
        if names.contains("message") { tables.insert(.v1) }
        if names.contains("session_message") { tables.insert(.v2) }
        return tables.isEmpty ? nil : tables
    }

    /// Ten usage columns in `parseRows` order, projected over the unioned table bodies so the two
    /// schemas can't drift apart.
    private static let dataProjection = """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 COALESCE(json_extract(data,'$.model.id'), json_extract(data,'$.modelID')),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id))
        FROM
        """

    private static let completedAssistant =
        "(json_type(data,'$.time.completed') IN ('integer','real') OR json_type(data,'$.finish') = 'text')"

    /// One table's eligible rows. OpenCode recorded OAuth Codex traffic as `$.providerID = 'openai'`
    /// on the v1 table and `$.model.providerID` on the v2 one; `role` is the per-schema completion
    /// predicate. The zero-cost filter is shared: the built-in Codex OAuth plugin writes every model
    /// rate as zero, so a positive cost is API-key traffic that must stay off the Codex card.
    private static func rowsSQL(table: String, role: String, creationCutoffMs: Int, extra: String = "") -> String {
        """
          SELECT time_created, id, data FROM \(table)
          WHERE time_created >= \(creationCutoffMs)
            AND json_valid(data)
            AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) = 'openai'
            AND json_type(data,'$.cost') IN ('integer','real')
            AND json_extract(data,'$.cost') = 0
            AND \(role)\(extra)
        """
    }

    /// `oauthSinceMs` bounds only the v2 branch: zero cost alone doesn't prove subscription usage
    /// there, because experimental 1.18.x builds recorded zero cost for paid API-key traffic too, so
    /// v2 rows count only from the OAuth credential's creation on. v1 rows priced paid traffic
    /// correctly and need no bound — and since the bound sits inside the v2 branch, a migrated v1 copy
    /// of an older row still survives the union and dedup.
    static func dataSQL(cutoffMs: Int, tables: MessageTables = .all, oauthSinceMs: Int? = nil) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        var bodies: [String] = []
        if tables.contains(.v1) {
            bodies.append(rowsSQL(
                table: "message",
                role: "json_extract(data,'$.role') = 'assistant' AND \(completedAssistant)",
                creationCutoffMs: creationCutoffMs
            ))
        }
        if tables.contains(.v2) {
            // Compaction summaries complete via `$.status`, not the assistant markers.
            bodies.append(rowsSQL(
                table: "session_message",
                role: "((type = 'assistant' AND \(completedAssistant)) OR (type = 'compaction' AND json_extract(data,'$.status') = 'completed'))",
                creationCutoffMs: creationCutoffMs,
                extra: oauthSinceMs.map {
                    "\n            AND COALESCE(json_extract(data,'$.time.completed'),time_created) >= \($0)"
                } ?? ""
            ))
        }
        let source = "(\n" + bodies.joined(separator: "\n          UNION ALL\n") + "\n        )"
        return "\(dataProjection)\n\(source)\nWHERE COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs);"
    }
}
