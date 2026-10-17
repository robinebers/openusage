import Foundation

/// Keeps rollout context alive across bounded JSONL batches without sharing it between files.
struct CodexLogFileParser: Sendable {
    private static let typeMarker = Data(#""type":""#.utf8)
    private static let turnContextToken = Data(#"turn_context""#.utf8)
    private static let tokenCountToken = Data(#"token_count""#.utf8)
    private static let sessionMetaToken = Data(#"session_meta""#.utf8)
    private static let taskStartedToken = Data(#"task_started""#.utf8)
    private static let threadSettingsToken = Data(#"thread_settings_applied""#.utf8)

    struct ParseState: Codable, Sendable, Equatable {
        var previousTotals: CodexLogUsageScanner.RawUsage?
        var currentModel: String?
        var currentTierIsFast = false
        var currentTierIsUltrafast = false
        var sawSessionMeta = false
        var replayGate: ChildReplayGate?
    }

    var state: ParseState

    init(state: ParseState = ParseState()) {
        self.state = state
    }

    mutating func parse(_ data: Data) -> [CodexLogUsageScanner.Event] {
        var events: [CodexLogUsageScanner.Event] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            var seesTurnContext = false
            var seesTokenCount = false
            var seesSessionMeta = false
            var seesTaskStarted = false
            var seesThreadSettings = false
            var cursor = line.startIndex
            while let found = line.range(of: Self.typeMarker, in: cursor..<line.endIndex) {
                let value = line[found.upperBound...]
                if value.starts(with: Self.turnContextToken) { seesTurnContext = true }
                else if value.starts(with: Self.tokenCountToken) { seesTokenCount = true }
                else if value.starts(with: Self.sessionMetaToken) { seesSessionMeta = true }
                else if value.starts(with: Self.taskStartedToken) { seesTaskStarted = true }
                else if value.starts(with: Self.threadSettingsToken) { seesThreadSettings = true }
                cursor = found.upperBound
            }

            let isTurnContext = seesTurnContext
            let isSessionMeta = !state.sawSessionMeta && seesSessionMeta
            let isTaskStarted = state.replayGate != nil && seesTaskStarted
            let isThreadSettings = seesThreadSettings
            guard isTurnContext || isSessionMeta || isTaskStarted || isThreadSettings
                || seesTokenCount
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                if let model = payload.flatMap(Self.modelName(in:)) {
                    state.currentModel = model
                }
                continue
            }
            // A child rollout also replays its parent's metadata; only its first metadata is its own.
            if type == "session_meta", !state.sawSessionMeta {
                state.sawSessionMeta = true
                if let payload, CodexLogUsageScanner.isChildSessionMeta(payload) {
                    if let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                       let created = OpenUsageISO8601.date(from: timestampRaw) {
                        state.replayGate = .untilStartedAt(created.timeIntervalSince1970.rounded(.down))
                    } else {
                        state.replayGate = .untilSelfTimedTaskStarted
                    }
                }
                continue
            }
            if isThreadSettings, type == "event_msg",
               payload?["type"] as? String == "thread_settings_applied" {
                if let tier = Self.serviceTier(in: payload) {
                    state.currentTierIsUltrafast = tier == "ultrafast"
                    state.currentTierIsFast = tier == "fast" || tier == "priority"
                }
                continue
            }
            guard type == "event_msg", let payload else { continue }

            // Replayed task starts retain the parent's older start time; the first live turn opens the gate.
            if payload["type"] as? String == "task_started" {
                if let gate = state.replayGate,
                   let startedAt = payload["started_at"] as? NSNumber,
                   gate.isCleared(byStartedAt: startedAt.doubleValue, lineTimestamp: object["timestamp"] as? String) {
                    state.replayGate = nil
                }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let timestamp = OpenUsageISO8601.date(from: timestampRaw)
            else { continue }

            let info = payload["info"] as? [String: Any]
            let totals = (info?["total_token_usage"] as? [String: Any]).map(CodexLogUsageScanner.RawUsage.init(json:))

            // Parent history still seeds cumulative totals, but must never become chargeable child usage.
            if state.replayGate != nil {
                if let totals { state.previousTotals = totals }
                continue
            }

            // Codex can repeat a cumulative snapshot without recording another completed turn.
            if let totals, let previous = state.previousTotals, totals.equalCounts(previous) {
                continue
            }

            let usage: CodexLogUsageScanner.RawUsage
            if let last = (info?["last_token_usage"] as? [String: Any]).map(CodexLogUsageScanner.RawUsage.init(json:)) {
                usage = last
            } else if let totals {
                usage = totals.subtracting(state.previousTotals)
            } else {
                continue
            }
            if let totals { state.previousTotals = totals }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { continue }

            let parsedModel = Self.modelName(in: payload) ?? info.flatMap(Self.modelName(in:))
            let model = CodexLogUsageScanner.resolveModel(parsed: parsedModel, currentModel: &state.currentModel)

            events.append(CodexLogUsageScanner.Event(
                timestamp: timestamp,
                model: model,
                pricingModel: model == "gpt-reserve" ? CodexLogUsageScanner.reservePricingModel : nil,
                input: usage.input,
                cached: min(usage.cached, usage.input),
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total,
                isFast: state.currentTierIsFast,
                isUltrafast: state.currentTierIsUltrafast
            ))
        }
        return events
    }

    private static func serviceTier(in payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let settings = payload["thread_settings"] as? [String: Any]
        for value in [settings?["service_tier"], payload["service_tier"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func modelName(in json: [String: Any]) -> String? {
        for value in [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    enum ChildReplayGate: Codable, Sendable, Equatable {
        /// Open once a turn starts at or after the child session's own creation time.
        case untilStartedAt(TimeInterval)
        /// Without creation metadata, compare the turn's start to its own log-line timestamp.
        case untilSelfTimedTaskStarted

        func isCleared(byStartedAt startedAt: TimeInterval, lineTimestamp: String?) -> Bool {
            switch self {
            case .untilStartedAt(let gate):
                return startedAt >= gate
            case .untilSelfTimedTaskStarted:
                guard let raw = lineTimestamp?.trimmingCharacters(in: .whitespaces),
                      let lineDate = OpenUsageISO8601.date(from: raw)
                else { return false }
                return startedAt >= lineDate.timeIntervalSince1970.rounded(.down)
            }
        }
    }
}
