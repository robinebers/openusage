import Foundation

/// Builds a per-day token/cost series from pi's session logs for one OpenUsage card, so usage that
/// happened inside pi (e.g. a Claude sub driven through pi) folds into that card's Usage Trend and
/// spend tiles alongside its native source.
///
/// Pi records an authoritative per-message `usage.cost.total` (like OpenCode), so that carried cost is
/// used when present; when pi logs a `$0` cost (subscription usage it doesn't impute), the tokens are
/// priced through the shared engine instead — the same `carried cost, else price` rule the Claude and
/// Codex log scanners use. Pi's usage shape differs from Claude Code's (`usage.input`/`output`,
/// nested `usage.cost.total`), so it has its own parser rather than routing through those scanners.
///
/// An actor holding the incremental parse cache (keyed path + size + mtime) so the ~5-minute refreshes
/// re-parse only changed session files. A single shared instance is used by every consuming provider,
/// so pi's logs are parsed once per refresh rather than once per card.
actor PiUsageScanner {
    static let shared = PiUsageScanner()

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner = IncrementalJSONLScanner<Entry>(logTag: LogTag.plugin("pi"))

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// One parsed assistant-message usage line. Raw timestamp is kept so a cached parse stays valid as
    /// the window slides; `cardID` is resolved at parse time so aggregation is a cheap filter.
    struct Entry: Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var cardID: String
        var model: String
        /// pi's own `usage.cost.total`, used directly when > 0; nil/0 falls through to engine pricing.
        var carriedCost: Double?
        /// The token buckets, for pricing the fall-through case.
        var tokens: TokenBreakdown
        /// pi's reported `usage.totalTokens`, shown as the row's token count (matches pi's own footer).
        var reportedTotalTokens: Int
    }

    /// Scan the last `daysBack` days of pi logs for one card. Returns nil when pi's sessions directory
    /// has no log files at all, so a provider with no pi usage folds in nothing.
    func scan(cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = PiPaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        let files = JSONLScanning.jsonlFiles(under: directory)
        guard !files.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let entries = await scanner.items(from: files, since: since, parse: Self.parseFile)
        return Self.aggregate(entries: Self.dedup(entries), cardID: cardID, since: since, pricing: pricing)
    }

    // MARK: - Parsing

    /// Parse every mapped assistant usage line of one session file. Lines for pi providers OpenUsage
    /// doesn't track are dropped here so they never reach aggregation.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil, let entry = parseLine(Data(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "message",
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let providerID = message["provider"] as? String,
              let cardID = PiProviderMapping.cardID(forPiProvider: providerID),
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let cacheWrite = Int(ProviderParse.number(usage["cacheWrite"]) ?? 0)
        let cacheWrite1h = Int(ProviderParse.number(usage["cacheWrite1h"]) ?? 0)
        let tokens = TokenBreakdown(
            input: Int(ProviderParse.number(usage["input"]) ?? 0),
            cacheWrite5m: max(cacheWrite - cacheWrite1h, 0),
            cacheWrite1h: cacheWrite1h,
            cacheRead: Int(ProviderParse.number(usage["cacheRead"]) ?? 0),
            output: Int(ProviderParse.number(usage["output"]) ?? 0)
        )

        let carriedCost = (usage["cost"] as? [String: Any]).flatMap { ProviderParse.number($0["total"]) }
        return Entry(
            id: object["id"] as? String,
            timestamp: timestamp,
            cardID: cardID,
            model: (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            carriedCost: carriedCost,
            tokens: tokens,
            reportedTotalTokens: Int(ProviderParse.number(usage["totalTokens"]) ?? 0)
        )
    }

    // MARK: - Dedup and aggregation

    /// Drop replayed lines that a forked/cloned session can duplicate under the same message id, keeping
    /// the first occurrence. Lines without an id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            if let id = entry.id, !seen.insert(id).inserted { continue }
            out.append(entry)
        }
        return out
    }

    /// Bucket the card's entries into local calendar days. Cost is pi's carried total when it recorded
    /// one, else the tokens priced through `pricing`; a model that can't be priced and carries no cost
    /// is excluded from the totals and surfaced as the tile's unknown-model warning, matching the log
    /// scanners.
    static func aggregate(entries: [Entry], cardID: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build()
    }
}
