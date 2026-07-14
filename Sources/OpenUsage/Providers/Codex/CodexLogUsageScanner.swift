import Foundation

/// Builds daily token/cost estimates for Codex by scanning the Codex CLI's local session rollouts
/// natively (`$CODEX_HOME/sessions/**/*.jsonl` + `archived_sessions/`), replacing the external
/// `ccusage` CLI.
///
/// Ports ccusage's Codex adapter semantics:
/// - Homes come from `CODEX_HOME` (comma-separated), else `~/.codex`. Each home contributes its
///   `sessions/` and `archived_sessions/` dirs; when both hold the same relative file path the
///   active `sessions/` copy wins.
/// - A `turn_context` line updates the session's current model; an `event_msg`/`token_count` line
///   carries the turn's usage — `last_token_usage` when present, else the delta against the previous
///   cumulative `total_token_usage`.
/// - Child sessions (subagents spawned via `thread_spawn`, and forks) replay the parent's entire
///   `token_count` history at spawn with rewritten timestamps. Those replayed lines are skipped —
///   they only seed the delta baseline — until the file's first live turn: a `task_started` whose
///   `started_at` is at or after the child session's own creation time (replayed `task_started`
///   lines carry the parent's original, older `started_at`). This is deliberately not time-window
///   based: a large parent history takes multiple seconds to replay, so any "same second" heuristic
///   undercuts it (that was the cause of a ~20x spend inflation).
/// - A `token_count` line whose cumulative `total_token_usage` is unchanged from the previous line
///   is a re-emitted stale snapshot, not new usage, and is skipped even when it carries a
///   `last_token_usage`.
/// - Early sessions without model metadata fall back to `gpt-5`; the retired `codex-auto-review`
///   slug maps to the codex model that was current at the line's date.
/// - Identical events (same timestamp + model + token counts) appearing in multiple files (copied
///   session logs) count once.
/// - Cost per event: `(input - cached) x input rate + cached x cache-read rate + output x output
///   rate`, all x the model's fast multiplier (default 2) when the user's `config.toml` requests
///   the fast/priority service tier. No 200k tiering — OpenAI doesn't price long context higher.
///
/// An actor for the same reasons as `ClaudeLogUsageScanner`: scans run off the main actor, and a
/// per-file parse cache keyed (path, size, mtime) makes the ~5-minute refresh re-parse only files
/// that changed.
actor CodexLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// One turn's token usage, normalized from a `token_count` line (deltas already applied).
    struct Event: Sendable, Equatable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    /// Off-main-actor incremental parse cache (keyed path + size + mtime), owned by the shared scanner.
    private let scanner = IncrementalJSONLScanner<Event>(logTag: LogTag.plugin("codex"))

    /// Scan the last `daysBack` days of Codex rollouts. Returns `nil` when no Codex home or no
    /// session files exist (the spend tiles then render "No data").
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let homes = codexHomes()
        let files = Self.sessionFiles(homes: homes)
        guard !files.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let events = await scanner.items(from: files, since: since, parse: Self.parseFile)
        return Self.aggregate(
            events: events, since: since, pricing: pricing, fastTier: usesFastServiceTier(homes: homes)
        )
    }

    // MARK: - Discovery

    /// `CODEX_HOME` entries (comma-separated) when set, else `~/.codex` — same as ccusage.
    private func codexHomes() -> [URL] {
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: expandHome($0)) }
        }
        return [homeDirectory().appendingPathComponent(".codex")]
    }

    /// Every rollout `*.jsonl` under each home's `sessions/` and `archived_sessions/` (a home with
    /// neither is scanned directly, ccusage's fallback). When both dirs of one home contain the same
    /// relative path, the `sessions/` copy wins — an archived duplicate must not double-count.
    private static func sessionFiles(homes: [URL]) -> [JSONLScanning.DiscoveredFile] {
        var files: [JSONLScanning.DiscoveredFile] = []
        var seenDirs: Set<String> = []
        for home in homes {
            var seenRelative: Set<String> = []
            var sourceDirs: [URL] = []
            for name in ["sessions", "archived_sessions"] {
                let dir = home.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sourceDirs.append(dir)
                }
            }
            if sourceDirs.isEmpty {
                sourceDirs = [home]
            }
            for dir in sourceDirs where seenDirs.insert(dir.path).inserted {
                for file in JSONLScanning.jsonlFiles(under: dir) {
                    let relative = String(file.path.dropFirst(dir.path.count))
                    guard seenRelative.insert(relative).inserted else { continue }
                    files.append(file)
                }
            }
        }
        return files
    }

    /// The user runs Codex on the fast/priority service tier (billed at the fast multiplier) when
    /// any home's `config.toml` sets `service_tier = "fast"` or `"priority"` — ccusage's detection.
    private func usesFastServiceTier(homes: [URL]) -> Bool {
        for home in homes {
            guard let content = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
            else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let setting = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first ?? ""
                guard let equals = setting.firstIndex(of: "=") else { continue }
                let key = setting[..<equals].trimmingCharacters(in: .whitespaces)
                guard key == "service_tier" else { continue }
                let value = setting[setting.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value == "fast" || value == "priority" { return true }
            }
        }
        return false
    }

    // MARK: - File parsing

    /// Parse one rollout file: track the current model from `turn_context`, normalize each
    /// `token_count` into a delta event, and skip a child session's replayed parent history
    /// (everything before the first live `task_started` — see the type doc).
    static func parseFile(_ data: Data) -> [Event] {
        let turnContextMarker = Data(#""type":"turn_context""#.utf8)
        let tokenCountMarker = Data(#""type":"token_count""#.utf8)
        let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
        let taskStartedMarker = Data(#""type":"task_started""#.utf8)

        var events: [Event] = []
        var previousTotals: RawUsage?
        var currentModel: String?
        var sawSessionMeta = false
        // Non-nil while inside a child session's replayed parent history: the child's creation
        // epoch (floored to the second, matching `started_at`'s integer resolution).
        var replayGateEpoch: TimeInterval?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isTurnContext = line.range(of: turnContextMarker) != nil
            let isSessionMeta = !sawSessionMeta && line.range(of: sessionMetaMarker) != nil
            let isTaskStarted = replayGateEpoch != nil && line.range(of: taskStartedMarker) != nil
            guard isTurnContext || isSessionMeta || isTaskStarted || line.range(of: tokenCountMarker) != nil
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                if let model = payload.flatMap(modelName(in:)) {
                    currentModel = model
                }
                continue
            }
            // Only the file's own (first) session_meta counts: a child file replays the parent's
            // session_meta lines right after its own.
            if type == "session_meta", !sawSessionMeta {
                sawSessionMeta = true
                if let payload, isChildSessionMeta(payload),
                   let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                   let created = OpenUsageISO8601.date(from: timestampRaw) {
                    replayGateEpoch = created.timeIntervalSince1970.rounded(.down)
                }
                continue
            }
            guard type == "event_msg", let payload else { continue }

            // The first task_started at/after the child's creation is the child's first live turn;
            // replayed task_started lines carry the parent's original, older started_at.
            if payload["type"] as? String == "task_started" {
                if let gate = replayGateEpoch,
                   let startedAt = payload["started_at"] as? NSNumber,
                   startedAt.doubleValue >= gate {
                    replayGateEpoch = nil
                }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let timestamp = OpenUsageISO8601.date(from: timestampRaw)
            else { continue }

            let info = payload["info"] as? [String: Any]
            let totals = (info?["total_token_usage"] as? [String: Any]).map(RawUsage.init(json:))

            // Replayed parent history: seed the delta baseline from it but never emit usage.
            if replayGateEpoch != nil {
                if let totals { previousTotals = totals }
                continue
            }

            // Unchanged cumulative totals mean a re-emitted stale snapshot (Codex does this), not
            // new usage — even when the line repeats a last_token_usage.
            if let totals, let previous = previousTotals, totals.equalCounts(previous) {
                continue
            }

            let usage: RawUsage
            if let last = (info?["last_token_usage"] as? [String: Any]).map(RawUsage.init(json:)) {
                usage = last
            } else if let totals {
                usage = totals.subtracting(previousTotals)
            } else {
                continue
            }
            if let totals { previousTotals = totals }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { continue }

            let parsedModel = modelName(in: payload) ?? info.flatMap(modelName(in:))
            let model = resolveModel(
                parsed: parsedModel,
                timestamp: timestampRaw,
                currentModel: &currentModel
            )

            events.append(Event(
                timestamp: timestamp,
                model: model,
                input: usage.input,
                cached: min(usage.cached, usage.input),
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total
            ))
        }
        return events
    }

    /// Token fields of a `token_count` usage object, tolerating the older field spellings ccusage
    /// accepts (`prompt_tokens`, `completion_tokens`, `cache_read_input_tokens`, …).
    struct RawUsage: Sendable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int

        init(json: [String: Any]) {
            func int(_ keys: String...) -> Int? {
                for key in keys {
                    if let number = json[key] as? NSNumber { return number.intValue }
                }
                return nil
            }
            input = int("input_tokens", "prompt_tokens", "input") ?? 0
            cached = int("cached_input_tokens", "cache_read_input_tokens", "cached_tokens") ?? 0
            output = int("output_tokens", "completion_tokens", "output") ?? 0
            reasoning = int("reasoning_output_tokens", "reasoning_tokens") ?? 0
            let reported = int("total_tokens") ?? 0
            let recomputed = input + output + reasoning
            total = (reported > 0 || recomputed == 0) ? reported : recomputed
        }

        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int) {
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
            self.total = total
        }

        /// Same token counts as `other` — an unchanged cumulative snapshot re-emitted by Codex.
        func equalCounts(_ other: RawUsage) -> Bool {
            input == other.input && cached == other.cached && output == other.output
                && reasoning == other.reasoning && total == other.total
        }

        /// Recover a turn delta from cumulative totals (used when `last_token_usage` is absent).
        func subtracting(_ previous: RawUsage?) -> RawUsage {
            RawUsage(
                input: max(0, input - (previous?.input ?? 0)),
                cached: max(0, cached - (previous?.cached ?? 0)),
                output: max(0, output - (previous?.output ?? 0)),
                reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0))
            )
        }
    }

    private static func modelName(in json: [String: Any]) -> String? {
        for value in [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// A session_meta payload marking the file as a child session (subagent spawn or fork) whose
    /// leading `token_count` lines replay the parent's history.
    static func isChildSessionMeta(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] != nil { return true }
        if payload["parent_thread_id"] != nil { return true }
        if payload["thread_source"] as? String == "subagent" { return true }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return true }
        return false
    }

    /// ccusage's model resolution: an explicit model on the line updates the session's current
    /// model; otherwise the tracked model applies; a session with no metadata at all falls back to
    /// `gpt-5`. The retired `codex-auto-review` slug maps to whichever codex model was current at
    /// the line's date.
    static func resolveModel(
        parsed: String?,
        timestamp: String,
        currentModel: inout String?
    ) -> String {
        if let parsed {
            currentModel = parsed
        }
        var model: String
        if let parsed {
            model = parsed
        } else if let current = currentModel {
            model = current
        } else {
            currentModel = "gpt-5"
            model = "gpt-5"
        }
        if model == Self.autoReviewModel {
            model = autoReviewFallback(at: timestamp)
        }
        return model
    }

    private static let autoReviewModel = "codex-auto-review"

    /// `codex-auto-review` release timeline (newest first), from ccusage's embedded snapshot: a
    /// line dated on/after a release prices as that codex model.
    private static let autoReviewFallbacks: [(releasedOn: String, model: String)] = [
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ]

    static func autoReviewFallback(at timestamp: String) -> String {
        let date = String(timestamp.prefix(10))
        guard date.count == 10, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return "gpt-5"
        }
        return autoReviewFallbacks.first(where: { date >= $0.releasedOn })?.model ?? "gpt-5"
    }

    // MARK: - Aggregation

    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    /// Bucket events into local calendar days. Identical events across files (copied session logs)
    /// count once. Cost is per-event codex math (see type doc).
    ///
    /// Events that can't be priced (an unknown model, or a blank slug) are excluded from every displayed
    /// total — tokens, dollars, the trend, and the model breakdown — because mixing measured tokens with
    /// unpriceable ones makes the figures incoherent. An unknown model's name lands in
    /// `unknownModelsByDay` (the tile's warning triangle), the only place unpriceable usage surfaces.
    /// A blank slug is unattributed, not unknown — there is no name to warn about.
    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing, fastTier: Bool
    ) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()

        for event in events where event.timestamp >= since {
            let key = EventKey(
                timestamp: event.timestamp, model: event.model, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
            guard seen.insert(key).inserted else { continue }

            let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            guard let model = trimmedModel, let rates = pricing.resolve(model: model) else {
                if let model = trimmedModel, event.total > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            let eventCost = cost(rates: rates, event: event, fastTier: fastTier)
            accumulator.add(day: day, tokens: event.total, cost: eventCost, model: model)
        }

        return accumulator.build()
    }

    /// Codex cost math (ccusage's): non-cached input at the input rate, cached input at the
    /// cache-read rate, output (reasoning included) at the output rate — no 200k tiers, no cache
    /// writes. On the fast tier the model's fast multiplier applies, defaulting to 2 when the
    /// pricing sources carry none.
    static func cost(rates: ModelRates, event: Event, fastTier: Bool) -> Double {
        let multiplier = fastTier ? (rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier) : 1
        let nonCached = max(0, event.input - event.cached)
        return (Double(nonCached) * rates.inputPerMillion
            + Double(event.cached) * rates.cacheReadPerMillion
            + Double(event.output) * rates.outputPerMillion) / 1_000_000 * multiplier
    }
}
