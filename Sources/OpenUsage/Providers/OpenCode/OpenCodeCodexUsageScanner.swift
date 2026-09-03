import Foundation

/// Reads Codex-subscription usage produced inside OpenCode and returns it in the same normalized shape
/// as Codex's native and pi scanners. OpenCode records both ChatGPT OAuth and ordinary OpenAI API-key
/// traffic as `providerID = openai`, so rows are eligible only while the local OpenCode credential is
/// explicitly OAuth. This avoids charging API-key traffic to the Codex subscription card.
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
        do {
            guard try authStore.hasCodexOAuth() else { return nil }
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
        for path in paths {
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
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
        guard failures.count < paths.count else { return nil }

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

    static func dataSQL(cutoffMs: Int) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        return """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 json_extract(data,'$.modelID'),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id))
        FROM message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = 'openai'
          AND json_type(data,'$.cost') IN ('integer','real')
          AND json_extract(data,'$.cost') = 0
          AND (json_type(data,'$.time.completed') IN ('integer','real')
               OR json_type(data,'$.finish') = 'text');
        """
    }
}
