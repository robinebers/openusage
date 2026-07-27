import Foundation

/// Builds daily token/cost estimates for Antigravity from its local SQLite conversation databases.
///
/// Antigravity's `~/.gemini/antigravity-cli/brain/**/transcript.jsonl` logs carry step/tool-call
/// records but *no* token accounting at all — the real per-generation token counts (and the model id
/// and wall-clock timestamp) live only in `~/.gemini/antigravity-cli/conversations/*.db`, one SQLite
/// file per conversation, in a `gen_metadata(idx, data, size)` table whose `data` column is an
/// undocumented protobuf blob (decoded by `extractAntigravityGenEvent`). This mirrors the fix already
/// shipped in the `tokenusage` CLI, which hit the same "jsonl has no tokens" dead end first.
///
/// Reads go through the shared `sqlite3` CLI (`SQLiteAccessing`), like the OpenCode/Cursor scanners —
/// never a direct SQLite library link. `hex(data)` avoids feeding raw binary through process stdout;
/// `json_group_array` bundles every row's hex blob into one string so a whole database is one query.
struct AntigravityDbUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var conversationsDirectory: @Sendable () -> String
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectory: @escaping @Sendable () -> String = AntigravityDbUsageScanner.defaultConversationsDirectory,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.conversationsDirectory = conversationsDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: readFailureWarning
        )
    }

    static let defaultConversationsDirectory: @Sendable () -> String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations").path
    }

    private static let dataSQL = "SELECT json_group_array(hex(data)) FROM gen_metadata"

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let dir = conversationsDirectory()
        let paths = Self.databaseFiles(in: dir)
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [dir], failingPaths: [])
            return nil
        }

        var accumulator = DailyUsageAccumulator()
        var checked: Set<String> = []
        var failing: Set<String> = []

        for path in paths {
            checked.insert(path)
            do {
                guard let hexArrayJSON = try sqlite.queryValue(path: path, sql: Self.dataSQL) else { continue }
                Self.parse(hexArrayJSON, since: since, pricing: pricing, into: &accumulator)
            } catch {
                failing.insert(path)
            }
        }

        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: failing)
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "usage query failed for \(path)")
        }

        let result = accumulator.build()
        if result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty { return nil }
        return result
    }

    /// Parses one database's `json_group_array(hex(data))` payload — a JSON array of hex-encoded
    /// protobuf blobs, one per `gen_metadata` row — accumulating every in-window, priced event.
    static func parse(_ hexArrayJSON: String, since: Date, pricing: ModelPricing, into accumulator: inout DailyUsageAccumulator) {
        guard let data = hexArrayJSON.data(using: .utf8),
              let hexStrings = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return }

        for hex in hexStrings {
            guard let blob = bytes(fromHex: hex),
                  let event = extractAntigravityGenEvent(blob)
            else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(event.timestampSecs))
            guard date >= since else { continue }

            let totalTokens = event.inputTokens + event.cacheReadTokens + event.outputTokens
            guard totalTokens > 0 else { continue }

            let day = DailyUsageAccumulator.dayKey(from: date)
            let breakdown = TokenBreakdown(input: event.inputTokens, cacheRead: event.cacheReadTokens, output: event.outputTokens)

            guard let cost = pricing.estimatedCostDollars(model: event.model, tokens: breakdown) else {
                accumulator.addUnknownModel(day: day, model: event.model)
                continue
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: event.model)
        }
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    /// Every `*.db` file directly under `dir` (conversation databases are not nested). A missing
    /// directory is the normal "never used Antigravity" case and returns `[]`.
    private static func databaseFiles(in dir: String) -> [String] {
        let expanded = expandHome(dir)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { return [] }
        return names
            .filter { $0.hasSuffix(".db") }
            .sorted()
            .map { expanded.trimmingTrailingSlashes + "/" + $0 }
    }
}
