import Foundation

/// Builds Grok's daily usage from completed turns in the CLI's durable session transcripts.
/// `logs/unified.jsonl` is a capped debug log, so it cannot back historical spend or reliable model
/// attribution. Session `updates.jsonl` files carry both per-model token counts and Grok's own costs.
actor GrokLogUsageScanner {
    private static let maximumPlausibleTokens = 1_000_000_000_000

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    /// One model's contribution to a completed turn. Event identifiers let copied session transcripts
    /// deduplicate the same notification without collapsing multiple models within that notification.
    struct Entry: Codable, Sendable, Equatable {
        var eventID: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var carriedCost: Double?
    }

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("grok"),
        persistence: JSONLScanCachePersistence(namespace: "grok", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Scan completed turns under `$GROK_HOME/sessions`, or `~/.grok/sessions` by default.
    /// Missing transcripts leave the spend tiles unbacked instead of falling back to the debug log.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = grokHome().appendingPathComponent("sessions", isDirectory: true)
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        // Child sessions can contain usage absent from their coordinator. Include every ledger;
        // dedup below removes replayed events by event ID and model, not by session kind or totals.
        let files = JSONLScanning.jsonlFiles(under: directory)
            .filter { URL(fileURLWithPath: $0.path).lastPathComponent == "updates.jsonl" }

        guard !files.isEmpty else {
            _ = await scanner.items(from: [], since: since, cacheIdentity: identity, parse: Self.parseFile)
            return nil
        }

        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: identity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
    }

    private func grokHome() -> URL {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandHome(raw))
        }
        return homeDirectory().appendingPathComponent(".grok", isDirectory: true)
    }

    // MARK: - Session parsing

    static func parseFile(_ data: Data) -> [Entry] {
        let completedTurnMarker = Data("turn_completed".utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: completedTurnMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            entries.append(contentsOf: parseCompletedTurn(object))
        }
        return entries
    }

    private static func parseCompletedTurn(_ object: [String: Any]) -> [Entry] {
        let params = object["params"] as? [String: Any]
        let update = (params?["update"] as? [String: Any]) ?? (object["update"] as? [String: Any])
        guard let update,
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any],
              let modelUsage = usage["modelUsage"] as? [String: Any],
              let timestamp = timestamp(in: object, params: params)
        else { return [] }

        let metadata = (params?["_meta"] as? [String: Any]) ?? (object["_meta"] as? [String: Any])
        let eventID = (metadata?["eventId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let topLevelTicks = ProviderParse.number(usage["costUsdTicks"])
        var entries: [Entry] = []

        for (rawModel, rawUsage) in modelUsage.sorted(by: { $0.key < $1.key }) {
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  let values = rawUsage as? [String: Any],
                  let inputValue = ProviderParse.number(values["inputTokens"]),
                  inputValue >= 0
            else { continue }

            let input = Self.boundedTokenCount(inputValue)
            let cacheRead = min(Self.boundedTokenCount(values["cachedReadTokens"]), input)
            let cacheWrite = min(
                Self.boundedTokenCount(values["cacheCreationTokens"]),
                input - cacheRead
            )
            // Grok reports reasoning as a subset of outputTokens, so it must never be added again.
            let output = Self.boundedTokenCount(values["outputTokens"])
            let ticks = ProviderParse.number(values["costUsdTicks"])
                ?? (modelUsage.count == 1 ? topLevelTicks : nil)
            let carriedCost = ticks.flatMap { $0 >= 0 ? $0 / 10_000_000_000 : nil }

            entries.append(Entry(
                eventID: eventID?.isEmpty == false ? eventID : nil,
                timestamp: timestamp,
                model: model,
                tokens: TokenBreakdown(
                    input: input - cacheRead - cacheWrite,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output
                ),
                carriedCost: carriedCost
            ))
        }
        return entries
    }

    /// External JSON numbers can exceed `Int.max`; cap corrupt counts before conversion or aggregation.
    private static func boundedTokenCount(_ value: Any?) -> Int {
        guard let number = ProviderParse.number(value), number > 0 else { return 0 }
        if number > Double(maximumPlausibleTokens) {
            AppLog.warn(LogTag.plugin("grok"), "Clamped an implausible token count in a Grok session transcript")
            return maximumPlausibleTokens
        }
        return Int(number)
    }

    private static func timestamp(in object: [String: Any], params: [String: Any]?) -> Date? {
        for metadata in [params?["_meta"], object["_meta"]] {
            guard let values = metadata as? [String: Any],
                  let milliseconds = ProviderParse.number(values["agentTimestampMs"]),
                  milliseconds > 0
            else { continue }
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }

        if let seconds = ProviderParse.number(object["timestamp"]), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = object["timestamp"] as? String {
            return OpenUsageISO8601.date(from: value)
        }
        return nil
    }

    // MARK: - Deduplication and aggregation

    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let eventID = entry.eventID else { return true }
            return seen.insert(eventID + "\0" + entry.model).inserted
        }
    }

    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            guard let cost = entry.carriedCost
                ?? pricing.estimatedCostDollars(model: entry.model, tokens: entry.tokens)
            else {
                if entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: entry.model)
                }
                continue
            }
            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }
}
