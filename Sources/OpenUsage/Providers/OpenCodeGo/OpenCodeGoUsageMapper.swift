import Foundation

struct OpenCodeGoUsageMapper {
    enum QuotaTarget: Hashable {
        case kimiForCoding
        case glm

        var label: String {
            switch self {
            case .kimiForCoding: return "Kimi for Coding"
            case .glm: return "GLM"
            }
        }
    }

    struct Candidate {
        var names: [String]
        var payload: [String: Any]
        var sourcePriority: Int
        var sourceOrder: Int
    }

    /// Parse usage payload into one or both quota lines.
    /// - Note: The real OpenCode Go payload shape is intentionally treated as soft:
    ///   dictionary-form quotas, quota arrays, and mixed `name + used / limit` shapes are all accepted.
    static func map(_ data: Data) -> [MetricLine] {
        guard ProviderParse.jsonObject(data) != nil else {
            return [.noUsageData]
        }
        return map(ProviderParse.jsonObject(data) ?? [:])
    }

    static func map(_ object: [String: Any]) -> [MetricLine] {
        let candidates = collectCandidates(object)

        var found: [QuotaTarget: (line: MetricLine, priority: Int, order: Int)] = [:]
        for candidate in candidates {
            guard let target = target(for: candidate),
                  let percent = percent(from: candidate.payload)
            else { continue }

            let line = progressLine(label: target.label, used: percent, payload: candidate.payload)
            if let existing = found[target],
               (existing.priority > candidate.sourcePriority ||
                (existing.priority == candidate.sourcePriority && existing.order < candidate.sourceOrder)) {
                continue
            }
            found[target] = (line: line, priority: candidate.sourcePriority, order: candidate.sourceOrder)
        }

        var lines = [MetricLine]()
        for target in [QuotaTarget.kimiForCoding, .glm] {
            if let entry = found[target] {
                lines.append(entry.line)
            }
        }

        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    // MARK: - Candidate collection

    private static func collectCandidates(_ object: [String: Any]) -> [Candidate] {
        var candidates: [Candidate] = []
        var order = 0

        func add(_ candidate: [String: Any], names: [String], sourcePriority: Int) {
            order += 1
            candidates.append(Candidate(names: names, payload: candidate, sourcePriority: sourcePriority, sourceOrder: order))
        }

        for key in ["quotas", "limits", "usage", "metrics"] where (object[key] as? [Any]).map({ !$0.isEmpty }) == true {
            let value = object[key]
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    add(entry, names: names(from: entry), sourcePriority: 3)
                }
            }
        }

        for key in ["quotas", "limits", "usage", "metrics"] where (object[key] as? [String: Any]).map({ !$0.isEmpty }) == true {
            let container = object[key] as! [String: Any]
            addContainerEntries(container, sourcePriority: 2)
        }

        if let nested = object["data"] as? [String: Any] {
            addContainerEntries(nested, sourcePriority: 2)
            for entry in arrayEntries(from: nested) {
                add(entry, names: names(from: entry), sourcePriority: 2)
            }
        }

        addContainerEntries(object, sourcePriority: 1)

        return candidates

        func addContainerEntries(_ container: [String: Any], sourcePriority: Int) {
            for (key, value) in container {
                if isMetadataKey(key) { continue }
                if let entry = payload(from: key, value: value) {
                    add(entry, names: [key], sourcePriority: sourcePriority)
                }
            }
        }

        func arrayEntries(from container: [String: Any]) -> [[String: Any]] {
            if let entries = container["quotas"] as? [[String: Any]] { return entries }
            if let entries = container["limits"] as? [[String: Any]] { return entries }
            return []
        }
    }

    private static func names(from payload: [String: Any]) -> [String] {
        var names: [String] = []
        if let name = payload["name"] as? String { names.append(name) }
        if let label = payload["label"] as? String { names.append(label) }
        if let metric = payload["metric"] as? String { names.append(metric) }
        if let id = payload["id"] as? String { names.append(id) }
        if let code = payload["code"] as? String { names.append(code) }
        return names
    }

    private static func isMetadataKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["status", "success", "code", "msg", "message", "error", "request_id", "timestamp", "updated_at", "updatedAt"].contains(lower)
    }

    private static func payload(from key: String, value: Any) -> [String: Any]? {
        if var entry = value as? [String: Any] {
            if entry["name"] == nil {
                entry["name"] = key
            }
            return entry
        }

        if let rawNumber = ProviderParse.number(value) {
            return ["name": key, "used_percent": rawNumber]
        }

        return nil
    }

    // MARK: - Mapping helpers

    private static func target(for candidate: Candidate) -> QuotaTarget? {
        let combined = normalize(candidate.names.joined(separator: " "))
        let explicitNames = candidate.names.map { normalize($0) }
        if explicitNames.contains(where: { isKimi($0) }) || isKimi(combined) { return .kimiForCoding }
        if explicitNames.contains(where: { isGLM($0) }) || isGLM(combined) { return .glm }
        return nil
    }

    private static func isKimi(_ text: String) -> Bool {
        text.contains("kimi") && text.contains("coding")
    }

    private static func isGLM(_ text: String) -> Bool {
        text.contains("glm")
    }

    private static func normalize(_ value: String) -> String {
        let replaced = value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return replaced
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func percent(from payload: [String: Any]) -> Double? {
        if let usedPercent = ProviderParse.number(payload["used_percent"])
            ?? ProviderParse.number(payload["usedPercent"])
            ?? ProviderParse.number(payload["percent"]) {
            return usedPercent
        }

        if let usage = ProviderParse.number(payload["used"]),
           let limit = ProviderParse.number(payload["limit"]) {
            // `limit` is expected when usage comes as raw quota usage.
            // Keep zero limits out to avoid false signals from malformed or unmetered responses.
            guard limit > 0 else { return nil }
            return (usage / limit) * 100
        }

        if let used = ProviderParse.number(payload["currentValue"]),
           let limit = ProviderParse.number(payload["max"])
            ?? ProviderParse.number(payload["total"])
            ?? ProviderParse.number(payload["quota"]) {
            guard limit > 0 else { return nil }
            return (used / limit) * 100
        }

        if let remaining = ProviderParse.number(payload["remaining"]),
           let limit = ProviderParse.number(payload["limit"]) {
            let remainingLimit = ProviderParse.number(payload["total"]) ?? limit
            // If the payload is remaining / total instead of used / limit, convert to usage percent.
            let used = max(0, remainingLimit - remaining)
            return remainingLimit > 0 ? (used / remainingLimit) * 100 : nil
        }

        return nil
    }

    private static func progressLine(label: String, used: Double, payload: [String: Any]) -> MetricLine {
        .progress(
            label: label,
            used: ProviderParse.clampPercent(used),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt(from: payload),
            periodDurationMs: periodDurationMs(from: payload)
        )
    }

    private static func resetsAt(from payload: [String: Any]) -> Date? {
        let candidates = [
            payload["resetsAt"],
            payload["reset_at"],
            payload["resetAt"],
            payload["nextResetTime"],
            payload["resetAtMs"],
            payload["nextResetAt"],
            payload["renewAt"],
            payload["expiresAt"]
        ]

        for raw in candidates.compactMap({ $0 }) {
            if let date = parsedDate(raw) {
                return date
            }
            if let seconds = ProviderParse.number(raw) {
                if seconds > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: seconds / 1000)
                }
                if seconds > 0 {
                    return Date(timeIntervalSince1970: seconds)
                }
            }
        }
        return nil
    }

    private static func periodDurationMs(from payload: [String: Any]) -> Int? {
        if let periodSeconds = ProviderParse.number(payload["periodSeconds"]) {
            return Int(periodSeconds * 1000)
        }
        if let periodMs = ProviderParse.number(payload["periodMs"]) {
            return Int(periodMs)
        }
        if let window = ProviderParse.number(payload["window"]), window > 0 {
            return Int(window * 1000)
        }
        return nil
    }

    private static func parsedDate(_ raw: Any) -> Date? {
        if let string = raw as? String {
            return OpenUsageISO8601.date(from: string)
        }
        return nil
    }
}
