import Foundation

/// Reads Codex-subscription usage produced inside OpenCode and returns it in the same normalized shape
/// as Codex's native and pi scanners. OpenCode records both ChatGPT OAuth and ordinary OpenAI API-key
/// traffic as `providerID = openai`, so rows are eligible only while the local OpenCode credential is
/// explicitly OAuth. This avoids charging API-key traffic to the Codex subscription card.
struct OpenCodeCodexUsageScanner: Sendable {
    private let authStore: OpenCodeAuthStore
    private let sqlite: SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths
    ) {
        self.authStore = authStore
        self.sqlite = sqlite
        self.databasePaths = databasePaths
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
        var failures: [String] = []
        for path in paths {
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                failures.append(path)
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "Codex usage query failed for \(path): \(error.localizedDescription)"
                )
            }
        }
        guard failures.count < paths.count else { return nil }

        var accumulator = DailyUsageAccumulator()
        for row in Self.deduplicated(rows) where row.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: row.timestamp)
            let model = row.model.nilIfEmpty
            let displayModel = model ?? ModelUsageEntry.unattributedModelName
            guard let model, let cost = pricing.estimatedCostDollars(model: model, tokens: row.tokens) else {
                if let model, row.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            accumulator.add(day: day, tokens: row.reportedTotalTokens, cost: cost, model: displayModel)
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
            let bucketTotal = clampedSum([input, cacheRead, cacheWrite, output, reasoning])
            let storedTotal = clampedTokens(values[2])
            return Row(
                id: (values[9] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                model: ((values[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: TokenBreakdown(
                    input: input,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: clampedSum([output, reasoning])
                ),
                reportedTotalTokens: bucketTotal > 0 ? bucketTotal : storedTotal
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

    private static func clampedSum(_ values: [Int]) -> Int {
        values.reduce(0) { min($0 + $1, 1_000_000_000_000_000) }
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
