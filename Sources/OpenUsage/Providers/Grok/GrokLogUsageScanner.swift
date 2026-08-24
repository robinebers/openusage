import Foundation

/// Builds Grok's daily usage from completed turns in the CLI's durable session transcripts.
/// `logs/unified.jsonl` is a capped debug log, so it cannot back historical spend or reliable model
/// attribution. Session `updates.jsonl` files carry both per-model token counts and Grok's own costs.
actor GrokLogUsageScanner {
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
        let files = JSONLScanning.jsonlFiles(under: directory)
            .filter(Self.isCoordinatorSession)

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

    /// Coordinator turns already include their subagents, so reading both ledgers would charge every
    /// child task twice. Older sessions without a summary remain eligible because their kind is unknown.
    private static func isCoordinatorSession(_ file: JSONLScanning.DiscoveredFile) -> Bool {
        let fileURL = URL(fileURLWithPath: file.path)
        guard fileURL.lastPathComponent == "updates.jsonl" else { return false }

        let summaryURL = fileURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else { return true }

        do {
            let data = try Data(contentsOf: summaryURL)
            guard let summary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.warn(LogTag.plugin("grok"), "Session summary is not a JSON object; skipped session")
                return false
            }
            guard let kind = summary["session_kind"] as? String else { return true }
            return !kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("subagent")
        } catch {
            AppLog.warn(LogTag.plugin("grok"), "Could not read session summary; skipped session: \(error.localizedDescription)")
            return false
        }
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

            let input = Int(inputValue)
            let cacheRead = min(max(Int(ProviderParse.number(values["cachedReadTokens"]) ?? 0), 0), input)
            let cacheWrite = min(
                max(Int(ProviderParse.number(values["cacheCreationTokens"]) ?? 0), 0),
                input - cacheRead
            )
            // Grok reports reasoning as a subset of outputTokens, so it must never be added again.
            let output = max(Int(ProviderParse.number(values["outputTokens"]) ?? 0), 0)
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
