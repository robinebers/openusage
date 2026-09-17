import Foundation

/// Reads Codex-subscription usage produced inside OpenCode and returns it in the same normalized shape
/// as Codex's native and pi scanners. OpenCode records both ChatGPT OAuth and ordinary OpenAI API-key
/// traffic as `providerID = openai`, so rows are eligible only while the local OpenCode credential is
/// explicitly OAuth. This avoids charging API-key traffic to the Codex subscription card.
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
        // Zero cost alone doesn't prove subscription usage: experimental 1.18.x builds recorded zero
        // cost for every request, including paid API-key traffic. v2 rows older than the OAuth
        // credential may be that paid history, so they are attributed only from the credential's
        // creation on. v1 rows priced paid traffic correctly and need no such bound.
        let oauthSince: Date?
        do {
            let oauth = try authStore.openAICredential()
            guard oauth.isOAuth else { return nil }
            oauthSince = oauth.since
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "Codex OAuth attribution skipped: \(error.localizedDescription)")
            return nil
        }

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
        // Only databases with message tables vote on the empty-vs-missing decision below.
        var usable: Set<String> = []
        for path in paths {
            let tables: OpenCodeMessageTables
            do {
                // A database with no message tables has nothing to contribute; skip it rather than let
                // the query fail and drop every other database's rows.
                guard let probed = try Self.messageTables(in: path, sqlite: sqlite) else { continue }
                tables = probed
            } catch {
                usable.insert(path)
                failures[path] = error.localizedDescription
                continue
            }
            usable.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs, tables: tables)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
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
        guard usable.isEmpty || failures.count < usable.count else { return nil }

        var accumulator = DailyUsageAccumulator()
        // Codex pricing depends only on the model slug, and resolving one walks every supplement alias
        // rule. Real histories run to thousands of rows across a handful of models, so resolve once each.
        var preparedByModel: [String: CodexUsagePricing.Prepared?] = [:]
        for row in Self.deduplicated(rows)
            where row.timestamp >= since && (row.source != "v2" || oauthSince.map({ row.timestamp >= $0 }) ?? true) {
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

    /// The message tables a database actually holds, or `nil` when it holds neither. Statement
    /// preparation fails on a missing table, so the query is built from this answer, not an assumption.
    private static func messageTables(in path: String, sqlite: SQLiteAccessing) throws -> OpenCodeMessageTables? {
        let output = try sqlite.queryValue(path: path, sql: OpenCodePaths.messageTablesSQL) ?? ""
        let tables = OpenCodePaths.messageTables(fromProbeOutput: output)
        return tables.isEmpty ? nil : tables
    }

    struct Row: Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
        /// Which table the row came from. v2 rows are bound to the OAuth credential's age; v1 rows
        /// priced paid traffic correctly and are not.
        var source: String = "v1"
    }

    /// Decodes `[completedAt, cost, total, model, input, cacheRead, cacheWrite, output, reasoning,
    /// id, source?]`. Older fixtures without the source marker decode as v1.
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
                reportedTotalTokens: tokens.totalTokens > 0 ? tokens.totalTokens : clampedTokens(values[2]),
                source: (values.count >= 11 ? values[10] as? String : nil) ?? "v1"
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

    /// Ten usage columns plus the source table, in `parseRows` order. The projection sits outside
    /// the union so the table combinations can't drift; each branch tags its own rows.
    private static let dataProjection = """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'), COALESCE(json_extract(data,'$.tokens.input'),0)+COALESCE(json_extract(data,'$.tokens.cache.read'),0)+COALESCE(json_extract(data,'$.tokens.cache.write'),0)+COALESCE(json_extract(data,'$.tokens.output'),0)+COALESCE(json_extract(data,'$.tokens.reasoning'),0)),
                 COALESCE(json_extract(data,'$.model.id'), json_extract(data,'$.modelID')),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id,
                 source))
        FROM
        """

    /// OpenCode recorded OAuth Codex traffic as `providerID = 'openai'` on the v1 table and
    /// `$.model.providerID` on the v2 one, and moved the role from `$.role` into the `type` column.
    /// Both branches keep the zero-cost filter: the built-in Codex OAuth plugin writes every model rate
    /// as zero, so a positive cost is API-key traffic that must stay off the Codex card. Compaction
    /// summaries complete via `$.status`, not the assistant markers, so they carry their own condition.
    private static func v1Rows(cutoffMs: Int, creationCutoffMs: Int) -> String {
        """
        SELECT time_created, id, data, 'v1' AS source FROM message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) = 'openai'
          AND json_type(data,'$.cost') IN ('integer','real')
          AND json_extract(data,'$.cost') = 0
          AND (json_type(data,'$.time.completed') IN ('integer','real')
               OR json_type(data,'$.finish') = 'text')
        """
    }

    private static func v2Rows(cutoffMs: Int, creationCutoffMs: Int) -> String {
        """
        SELECT time_created, id, data, 'v2' AS source FROM session_message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) = 'openai'
          AND json_type(data,'$.cost') IN ('integer','real')
          AND json_extract(data,'$.cost') = 0
          AND ((type = 'assistant'
                AND (json_type(data,'$.time.completed') IN ('integer','real')
                     OR json_type(data,'$.finish') = 'text'))
               OR (type = 'compaction' AND json_extract(data,'$.status') = 'completed'))
        """
    }

    /// One table or two, the body is always a subquery so the projection above can read `FROM` it
    /// uniformly. Callers never pass an empty set — a database with no message tables is skipped
    /// before any SQL is built.
    private static func rowsSource(_ tables: OpenCodeMessageTables, v1: String, v2: String) -> String {
        let bodies = [
            tables.contains(.v1) ? v1 : nil,
            tables.contains(.v2) ? v2 : nil,
        ].compactMap { $0 }
        return "(\n" + bodies.map(indented).joined(separator: "\n          UNION ALL\n") + "\n        )"
    }

    private static func indented(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }
            .joined(separator: "\n")
    }

    static func dataSQL(cutoffMs: Int, tables: OpenCodeMessageTables = .all) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        let source = rowsSource(
            tables,
            v1: v1Rows(cutoffMs: cutoffMs, creationCutoffMs: creationCutoffMs),
            v2: v2Rows(cutoffMs: cutoffMs, creationCutoffMs: creationCutoffMs)
        )
        return "\(dataProjection)\n\(source)\nWHERE COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs);"
    }
}
