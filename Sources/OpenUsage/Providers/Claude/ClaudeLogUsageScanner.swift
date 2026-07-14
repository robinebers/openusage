import Foundation

/// Builds daily token/cost estimates for Claude by scanning Claude Code's local session logs
/// natively (`<config dir>/projects/**/*.jsonl`), replacing the external `ccusage` CLI.
///
/// Ports ccusage's Claude adapter semantics:
/// - Roots come from `CLAUDE_CONFIG_DIR` (comma-separated; each entry is a config dir containing
///   `projects/`, or the `projects/` dir itself), else `$XDG_CONFIG_HOME/claude` and `~/.claude`.
/// - A usage line must carry `"usage":{`, parse as JSON with a valid timestamp, not carry `null` in
///   fields Claude never writes as null, and pass the validity checks (semver-ish `version`,
///   non-empty ids/model).
/// - Entries are deduplicated by `(message.id, requestId)`, with a second pass that catches
///   sidechain logs replaying a parent message under a new request id. On collision the non-sidechain
///   entry wins, then the larger token total, then the one carrying a `speed` field.
/// - Advisor-message iterations become separate entries under their own model. Other iteration
///   types stay represented only by the parent usage totals, avoiding double-counting.
/// - Cost mode "auto": a line's `costUSD` when present, else tokens priced through `ModelPricing`.
///
/// An actor so the whole scan runs off the main actor, and so the per-file parse cache (keyed by
/// path + size + mtime) can persist across refreshes: the ~5-minute provider refresh re-parses only
/// files that changed, then re-runs the cheap dedup + day aggregation over cached entries.
actor ClaudeLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// One parsed usage line. Token buckets are pre-normalized into `TokenBreakdown`; dedup fields
    /// ride along so the global dedup pass can run over cached entries.
    struct Entry: Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.isFast` says it was "fast".
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// `nil` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
        var model: String?
    }

    /// Off-main-actor incremental parse cache (keyed path + size + mtime), owned by the shared scanner.
    private let scanner = IncrementalJSONLScanner<Entry>(logTag: LogTag.plugin("claude"))

    /// Scan the last `daysBack` days of Claude logs. Returns `nil` when no Claude data directory or
    /// no log files exist (the spend tiles then render "No data"); returns an empty series when logs
    /// exist but have no usage in the window.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let roots = claudeRoots()
        guard !roots.isEmpty else { return nil }

        let files = Self.usageFiles(under: roots)
        guard !files.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        // Entries come back concatenated in path-sorted file order, so dedup's keep-first is deterministic.
        let entries = await scanner.items(from: files, since: since, parse: Self.parseFile)
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
    }

    // MARK: - Root and file discovery

    /// Claude config directories that actually contain a `projects/` folder, in ccusage's order:
    /// every entry of `CLAUDE_CONFIG_DIR` when set (an invalid list logs and yields none), else
    /// `$XDG_CONFIG_HOME/claude` (default `~/.config/claude`) and `~/.claude`. Cowork's per-session
    /// `.claude` sandboxes are always appended — they live under the desktop app's own container,
    /// so `CLAUDE_CONFIG_DIR` (a terminal-CLI override) doesn't speak for them.
    private func claudeRoots() -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func addIfValid(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path),
                  seen.insert(url.path).inserted
            else { return }
            roots.append(url)
        }

        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                // Accept the `projects/` directory itself as an alias for its parent config dir.
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
            if roots.isEmpty {
                AppLog.warn(LogTag.plugin("claude"), "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/: \(raw)")
            }
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }

        for sandbox in Self.coworkClaudeDirs(home: homeDirectory()) {
            addIfValid(sandbox)
        }
        return roots
    }

    /// The `.claude` dirs Cowork (the Claude desktop app's agent mode) creates, one per session,
    /// under `~/Library/Application Support/Claude/local-agent-mode-sessions/<group>/<sub>/local_*`
    /// (plus an `agent/local_*` variant one level deeper). Each holds the same `projects/**/*.jsonl`
    /// session logs as `~/.claude`, so they scan as additional roots. The walk is bounded to those
    /// known levels — session dirs contain full sandbox homes we must not recurse into.
    private static func coworkClaudeDirs(home: URL) -> [URL] {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        func subdirectories(of url: URL) -> [URL] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        var dirs: [URL] = []
        for group in subdirectories(of: base) {
            for sub in subdirectories(of: group) {
                var sessions = subdirectories(of: sub)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: subdirectories(of: holder))
                }
                for session in sessions {
                    dirs.append(session.appendingPathComponent(".claude"))
                }
            }
        }
        return dirs.sorted { $0.path < $1.path }
    }

    /// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins)
    /// is deterministic — the same order ccusage scans in.
    private static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        roots
            .flatMap { JSONLScanning.jsonlFiles(under: $0.appendingPathComponent("projects")) }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Line parsing

    /// Parse every usage line of one session file. Entries keep their raw timestamps — the date
    /// window is applied at aggregation so a cached parse stays valid as the window slides.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            if hasUnsupportedNullField(line) { continue }
            entries.append(contentsOf: parseEntries(Data(line)))
        }
        return entries
    }

    /// Decode one JSONL line into an `Entry`, mirroring what ccusage's serde model accepts: `usage`
    /// with numeric `input_tokens`/`output_tokens` is required, everything else optional, and a
    /// malformed or invalid line is skipped rather than failing the file.
    static func parseLine(_ data: Data) -> Entry? {
        parseEntries(data).first
    }

    /// A Claude log line can carry nested advisor work in `usage.iterations`. The top-level usage
    /// remains the main-model entry; only advisor-message iterations become additional entries,
    /// matching ccusage without recounting the ordinary message iterations that feed that total.
    private static func parseEntries(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        for iteration in iterations {
            guard iteration["type"] as? String == "advisor_message",
                  let advisorModel = iteration["model"] as? String,
                  !advisorModel.isEmpty,
                  let advisorUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy
        // aggregate `cache_creation_input_tokens` treated as all-5m.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cacheWrite5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        return (TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        ), speed != nil)
    }

    /// ccusage's validity rules: a `version` that isn't semver-ish marks a foreign log format, and
    /// ids/model that are present but empty mark a malformed line.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// `digits.digits.digit…` — accepts "1.0.24" and pre-release suffixes, rejects e.g. "unknown".
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// Claude never writes `null` into these fields; a line that does is a foreign/corrupt shape that
    /// ccusage skips before JSON parsing, and we match it byte-for-byte.
    static func hasUnsupportedNullField(_ line: Data.SubSequence) -> Bool {
        let nullMarker = Data(":null".utf8)
        let quote = UInt8(ascii: "\"")
        let bytes = Data(line) // fresh copy → indices are 0-based
        var offset = bytes.startIndex
        while let markerRange = bytes.range(of: nullMarker, in: offset..<bytes.endIndex) {
            let start = markerRange.lowerBound
            var fieldEnd = start > 0 ? start - 1 : 0
            if bytes[fieldEnd] != quote {
                while fieldEnd > 0, bytes[fieldEnd] != quote { fieldEnd -= 1 }
            }
            if bytes[fieldEnd] == quote, fieldEnd > 0 {
                var fieldStart = fieldEnd - 1
                while fieldStart > 0, bytes[fieldStart] != quote { fieldStart -= 1 }
                if bytes[fieldStart] == quote {
                    let field = String(decoding: bytes[(fieldStart + 1)..<fieldEnd], as: UTF8.self)
                    if Self.unsupportedNullableFields.contains(field) { return true }
                }
            }
            offset = markerRange.upperBound
        }
        return false
    }

    private static let unsupportedNullableFields: Set<String> = [
        "id", "cwd", "model", "speed", "costUSD", "version", "sessionId", "requestId",
        "isApiErrorMessage", "cache_read_input_tokens", "cache_creation_input_tokens"
    ]

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// Drop replayed usage lines, keeping ccusage's preferences. Entries are keyed by
    /// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that
    /// replay a parent message under a new request id. On a collision the existing entry is replaced
    /// only when the candidate wins `shouldReplace`. Entries without a message id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var exactIndex: [ExactKey: Int] = [:]
        var messageIndex: [String: [Int]] = [:]

        for entry in entries {
            guard let messageID = entry.messageID else {
                deduped.append(entry)
                continue
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || deduped[index].isSidechain
            })

            if let index = collision {
                if shouldReplace(candidate: entry, existing: deduped[index]) {
                    let old = deduped[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    deduped[index] = entry
                    exactIndex[key] = index
                }
                continue
            }

            let index = deduped.count
            deduped.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
        return deduped
    }

    /// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token
    /// total, then the entry that carries a `speed` field (richer log shape).
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    // MARK: - Aggregation

    /// Bucket deduplicated entries into local calendar days. Cost mode "auto": a line's `costUSD`
    /// when present, else tokens priced through `pricing`.
    ///
    /// Entries that can't be priced (an unknown model, or unattributed tokens with no carried cost)
    /// are excluded from every displayed total — tokens, dollars, the trend, and the model breakdown —
    /// because mixing measured tokens with unpriceable ones makes the figures incoherent. An unknown
    /// model's name lands in `unknownModelsByDay` (the tile's warning triangle), the only place
    /// unpriceable usage surfaces.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        return accumulator.build()
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
