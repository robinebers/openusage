import Foundation

enum ZAIUsageMapper {
    static func map(quotaBody: Data, subscriptionBody: Data?) throws -> ProviderUsage {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        return ProviderUsage(plan: plan, lines: try mapQuota(quotaBody))
    }

    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ProviderError.invalidResponse
        }
        if (root["success"] as? Bool) == false,
           (root["msg"] as? String)?.localizedCaseInsensitiveContains("coding plan") == true {
            throw ProviderError.unavailable("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
        }
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ProviderError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        guard !limits.isEmpty else {
            return []
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        let percentageLimits = limits.filter {
            let type = ($0["type"] as? String) ?? ($0["name"] as? String)
            return type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT"
        }
        for entry in percentageLimits {
            guard let window = try classifyTokenWindow(entry) else { continue }
            sawRecognizedLimit = true
            switch window {
            case .session(let periodMs):
                lines.append(try percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(try percentLine(entry, label: "Weekly", periodMs: periodMs))
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            sawRecognizedLimit = true
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ProviderError.invalidResponse }
            return []
        }
        return lines
    }

    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        else {
            return nil
        }
        return name
    }

    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            throw ProviderError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            throw ProviderError.invalidResponse
        }
        let periodMs = Int(duration)
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            throw ProviderError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .percent(label, percentage, resetsAt: resetsAt, periodMs: periodMs)
    }

    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            throw ProviderError.invalidResponse
        }
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: MetricPeriod.monthMs
        )
    }

    /// A limit entry matches by `type` or `name`: Z.ai's payload has used either field across revisions.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
