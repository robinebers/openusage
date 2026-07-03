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

    private struct CachedFile {
        var size: Int
        var mtime: Date
        var entries: [Entry]
    }

    private var fileCache: [String: CachedFile] = [:]

    /// Scan the last `daysBack` days of Claude logs. Returns `nil` when no Claude data directory or
    /// no log files exist (the spend tiles then render "No data"); returns an empty series when logs
    /// exist but have no usage in the window.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let roots = claudeRoots()
        guard !roots.isEmpty else { return nil }

        let files = Self.usageFiles(under: roots)
        guard !files.isEmpty else { return nil }

        let since = Self.sinceDate(daysBack: daysBack, now: now)
        var nextCache: [String: CachedFile] = [:]
        var toParse: [DiscoveredFile] = []
        for file in files {
            // A file whose last write predates the window can't contain in-window entries; skip the
            // parse (and drop any cache) so a years-deep `projects/` tree stays cheap to rescan.
            guard file.mtime >= since else { continue }
            if let cached = fileCache[file.path], cached.size == file.size, cached.mtime == file.mtime {
                nextCache[file.path] = cached
            } else {
                toParse.append(file)
            }
        }
        for (file, parsed) in await Self.parseFiles(toParse) {
            // An unreadable file is skipped, not cached, so a transient read failure doesn't stick.
            guard let parsed else { continue }
            nextCache[file.path] = CachedFile(size: file.size, mtime: file.mtime, entries: parsed)
        }
        fileCache = nextCache

        // Concatenate in path-sorted file order so dedup's keep-first preference is deterministic.
        var entries: [Entry] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            entries.append(contentsOf: cached.entries)
        }
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
    }

    /// Read + parse the changed files in parallel (they're independent; the first scan of a heavy
    /// `projects/` tree is CPU-bound on JSON decoding). Results come back keyed to the input order;
    /// a `nil` entry list marks an unreadable file.
    private static func parseFiles(_ files: [DiscoveredFile]) async -> [(DiscoveredFile, [Entry]?)] {
        await withTaskGroup(of: (Int, [Entry]?).self, returning: [(DiscoveredFile, [Entry]?)].self) { group in
            for (index, file) in files.enumerated() {
                group.addTask {
                    guard let data = FileManager.default.contents(atPath: file.path) else {
                        return (index, nil)
                    }
                    return (index, parseFile(data))
                }
            }
            var results: [(DiscoveredFile, [Entry]?)] = files.map { ($0, nil) }
            for await (index, entries) in group {
                results[index] = (files[index], entries)
            }
            return results
        }
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

    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
    }

    /// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins)
    /// is deterministic — the same order ccusage scans in.
    private static func usageFiles(under roots: [URL]) -> [DiscoveredFile] {
        var files: [DiscoveredFile] = []
        for root in roots {
            let projects = root.appendingPathComponent("projects")
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(
                at: projects, includingPropertiesForKeys: keys, options: []
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { continue }
                files.append(DiscoveredFile(
                    path: url.path,
                    size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
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
            if let entry = parseLine(Data(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Decode one JSONL line into an `Entry`, mirroring what ccusage's serde model accepts: `usage`
    /// with numeric `input_tokens`/`output_tokens` is required, everything else optional, and a
    /// malformed or invalid line is skipped rather than failing the file.
    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        guard isValidEntry(object, message: message) else { return nil }

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

        let tokens = TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        )

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        return Entry(
            timestamp: timestamp,
            tokens: tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: speed != nil,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )
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
        let nullMarker = Array(":null".utf8)
        let quote = UInt8(ascii: "\"")
        let bytes = Array(line)
        var offset = 0
        while let start = firstRange(of: nullMarker, in: bytes, from: offset) {
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
            offset = start + nullMarker.count
        }
        return false
    }

    private static let unsupportedNullableFields: Set<String> = [
        "id", "cwd", "model", "speed", "costUSD", "version", "sessionId", "requestId",
        "isApiErrorMessage", "cache_read_input_tokens", "cache_creation_input_tokens"
    ]

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8], from offset: Int) -> Int? {
        guard needle.count <= haystack.count - offset else { return nil }
        for start in offset...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }

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
    /// when present, else tokens priced through `pricing`. A model no source can price contributes
    /// $0 and lands in `unknownModelsByDay` (the tile's warning triangle); a day where nothing could
    /// be priced keeps `costUSD` nil so the tile shows just the token count.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var tokensByDay: [String: Int] = [:]
        var costByDay: [String: Double] = [:]
        var pricedDays: Set<String> = []
        var unknownModelsByDay: [String: Set<String>] = [:]

        for entry in entries where entry.timestamp >= since {
            let day = dayKey(from: entry.timestamp)
            tokensByDay[day, default: 0] += entry.tokens.totalTokens

            if let carried = entry.costUSD {
                costByDay[day, default: 0] += carried
                pricedDays.insert(day)
            } else if let model = entry.model {
                if let cost = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                    costByDay[day, default: 0] += cost
                    pricedDays.insert(day)
                } else if entry.tokens.totalTokens > 0 {
                    unknownModelsByDay[day, default: []].insert(model)
                }
            }
        }

        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(
                date: day,
                totalTokens: tokensByDay[day] ?? 0,
                costUSD: pricedDays.contains(day) ? (costByDay[day] ?? 0) : nil
            )
        }
        return LogUsageScan(series: DailyUsageSeries(daily: days), unknownModelsByDay: unknownModelsByDay)
    }

    /// Local calendar day as `yyyy-MM-dd`, matching `SpendTileMapper`'s day keys.
    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
