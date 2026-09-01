import Foundation

/// Keeps rollout context alive across bounded JSONL batches without sharing it between files.
struct CodexLogFileParser: Sendable {
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
    private static let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
    private static let taskStartedMarker = Data(#""type":"task_started""#.utf8)
    private static let threadSettingsMarker = Data(#""type":"thread_settings_applied""#.utf8)

    private var previousTotals: CodexLogUsageScanner.RawUsage?
    private var currentModel: String?
    private var currentTierIsFast = false
    private var sawSessionMeta = false
    private var replayGate: ChildReplayGate?

    mutating func parse(_ data: Data) -> [CodexLogUsageScanner.Event] {
        var events: [CodexLogUsageScanner.Event] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isTurnContext = line.range(of: Self.turnContextMarker) != nil
            let isSessionMeta = !sawSessionMeta && line.range(of: Self.sessionMetaMarker) != nil
            let isTaskStarted = replayGate != nil && line.range(of: Self.taskStartedMarker) != nil
            let isThreadSettings = line.range(of: Self.threadSettingsMarker) != nil
            guard isTurnContext || isSessionMeta || isTaskStarted || isThreadSettings
                || line.range(of: Self.tokenCountMarker) != nil
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                if let model = payload.flatMap(Self.modelName(in:)) {
                    currentModel = model
                }
                continue
            }
            // A child rollout also replays its parent's metadata; only its first metadata is its own.
            if type == "session_meta", !sawSessionMeta {
                sawSessionMeta = true
                if let payload, CodexLogUsageScanner.isChildSessionMeta(payload) {
                    if let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                       let created = OpenUsageISO8601.date(from: timestampRaw) {
                        replayGate = .untilStartedAt(created.timeIntervalSince1970.rounded(.down))
                    } else {
                        replayGate = .untilSelfTimedTaskStarted
                    }
                }
                continue
            }
            if isThreadSettings, type == "event_msg",
               payload?["type"] as? String == "thread_settings_applied" {
                if let tier = Self.serviceTier(in: payload) {
                    currentTierIsFast = tier == "fast" || tier == "priority"
                }
                continue
            }
            guard type == "event_msg", let payload else { continue }

            // Replayed task starts retain the parent's older start time; the first live turn opens the gate.
            if payload["type"] as? String == "task_started" {
                if let gate = replayGate,
                   let startedAt = payload["started_at"] as? NSNumber,
                   gate.isCleared(byStartedAt: startedAt.doubleValue, lineTimestamp: object["timestamp"] as? String) {
                    replayGate = nil
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
            if replayGate != nil {
                if let totals { previousTotals = totals }
                continue
            }

            // Codex can repeat a cumulative snapshot without recording another completed turn.
            if let totals, let previous = previousTotals, totals.equalCounts(previous) {
                continue
            }

            let usage: CodexLogUsageScanner.RawUsage
            if let last = (info?["last_token_usage"] as? [String: Any]).map(CodexLogUsageScanner.RawUsage.init(json:)) {
                usage = last
            } else if let totals {
                usage = totals.subtracting(previousTotals)
            } else {
                continue
            }
            if let totals { previousTotals = totals }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { continue }

            let parsedModel = Self.modelName(in: payload) ?? info.flatMap(Self.modelName(in:))
            let model = CodexLogUsageScanner.resolveModel(parsed: parsedModel, currentModel: &currentModel)

            events.append(CodexLogUsageScanner.Event(
                timestamp: timestamp,
                model: model,
                pricingModel: model == "codex-auto-review"
                    ? CodexLogUsageScanner.autoReviewFallback(at: timestampRaw)
                    : nil,
                input: usage.input,
                cached: min(usage.cached, usage.input),
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total,
                isFast: currentTierIsFast
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

    private enum ChildReplayGate: Sendable {
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
