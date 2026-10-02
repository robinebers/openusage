import Foundation

/// Reads Zcode's local SQLite accounting (`~/.zcode/cli/db/*.sqlite`) for the spend tiles and usage
/// trend. Cookie-free and local-only: Zcode records per-request token counts for every model call it
/// makes, and OpenUsage prices them itself through the shared pricing store — so plan/subscription
/// traffic reads as an *estimate* (the ⓘ marker), exactly like Claude, Codex, and Grok.
///
/// A `Sendable` struct (like the OpenCode scanner), `async` and nonisolated, so the SQLite reads run
/// off the main actor when the `@MainActor` provider `await`s it.
struct ZcodeUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = ZcodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("zcode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let home = ZcodePaths.homeDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try ZcodePaths.databaseFiles(in: home)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no Zcode database at all; a
    /// present-but-empty database yields an empty scan (idle tiles collapse to "No data" via
    /// `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none could be read.
    func scan(
        daysBack: Int = 30,
        now: Date = Date(),
        pricing: ModelPricing
    ) async throws -> LogUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The database directory exists but couldn't be enumerated — same failure class as
            // unreadable databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<database directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("zcode"), "database directory unreadable: \(error.localizedDescription)")
            }
            throw ZcodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        // Same calendar bound the tiles/trend use. A wall-clock `now - daysBack×86400` cutoff sits
        // later the same day, so morning rows on the oldest day never leave SQLite.
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: try Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
                continue
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("zcode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw ZcodeUsageError.databaseUnreadable
        }

        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= since else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            let tokens = row.tokens
            guard tokens.totalTokens > 0 else { continue }
            guard let cost = pricing.estimatedCostDollars(model: row.model, tokens: tokens) else {
                // Tokens with no known price are still counted nowhere here — consistent with the other
                // local scanners, which keep only priced rows and raise the tile's warning triangle.
                accumulator.addUnknownModel(day: day, model: row.model)
                continue
            }
            accumulator.add(day: day, tokens: tokens.totalTokens, cost: cost, model: row.model)
        }
        return accumulator.build()
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any database hold at least one model request
    /// that recorded tokens? Read-only, no network. Failures are logged (this runs only during
    /// first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// database counts as a Zcode footprint so `refresh()` gets to surface the real error.
    func hasModelUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("zcode"), "usage probe: database directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("zcode"), "usage probe failed for \(path): \(error.localizedDescription)")
                return true
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var model: String
        var tokens: TokenBreakdown
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[started_at, model_id, input_tokens, output_tokens, cache_read, cache_creation]`. Rows with a
    /// missing timestamp are skipped at this boundary.
    ///
    /// Zcode normalizes provider usage into Anthropic-style buckets where **`input_tokens` already
    /// includes cache reads and cache writes** (verified against the raw `providerMetadata.anthropic`
    /// payload in its rollout logs: `input_tokens: 11340`, `cache_read_input_tokens: 63872`,
    /// normalized `inputTokens: 75212`). The non-cached remainder is what bills at the plain input
    /// rate, so it is derived here rather than summed twice.
    private static func parseRows(_ json: String) throws -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { throw SQLiteError.queryFailed("Invalid Zcode usage query response.") }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 6,
                  let ms = ProviderParse.number(entry[0]), ms > 0
            else { continue }
            let model = (entry[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rowInput = Self.clampedInt(entry[2])
            let output = Self.clampedInt(entry[3])
            let cacheRead = Self.clampedInt(entry[4])
            let cacheWrite = Self.clampedInt(entry[5])
            // Clamped at zero so a corrupt or already-deduplicated count can't produce negative tokens.
            let input = max(rowInput - cacheRead - cacheWrite, 0)
            rows.append(Row(
                ms: ms,
                model: model.isEmpty ? Self.unknownModel : model,
                tokens: TokenBreakdown(
                    input: input,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output
                )
            ))
        }
        return rows
    }

    /// `Int(Double)` traps above `Int.max`, and a corrupt count would otherwise crash the refresh.
    /// 1e15 is far above any real per-request token count.
    private static func clampedInt(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    /// Shown in the unknown-model warning for a row whose `model_id` is blank.
    static let unknownModel = "Unknown Zcode Model"

    // MARK: - SQL

    /// Only rows that actually moved tokens: an errored or cancelled request logs zeroed counts, and
    /// `started_at` is indexed, so the cutoff stays cheap.
    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 started_at,
                 model_id,
                 input_tokens,
                 output_tokens,
                 cache_read_input_tokens,
                 cache_creation_input_tokens))
        FROM model_usage
        WHERE started_at >= \(cutoffMs)
          AND (input_tokens + output_tokens
               + cache_read_input_tokens + cache_creation_input_tokens) > 0;
        """
    }

    static let probeSQL = """
        SELECT 1 FROM model_usage
        WHERE (input_tokens + output_tokens
               + cache_read_input_tokens + cache_creation_input_tokens) > 0
        LIMIT 1;
        """
}
