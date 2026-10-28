import Foundation

enum CopilotUsageMapper {
    static let periodMs = MetricPeriod.monthMs

    static func map(_ response: HTTPResponse) throws -> ProviderUsage {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }
        return try map(body: body)
    }

    static func map(body: [String: Any]) throws -> ProviderUsage {
        let plan = planLabel(body["copilot_plan"])
        let resetsAt = parseResetDate(body["quota_reset_date"])
            ?? parseResetDate(body["limited_user_reset_date"])

        var lines: [MetricLine] = []

        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"]
        let creditsLine = snapshotLine(label: "Credits", premium, resetsAt: resetsAt)
        appendIfPresent(&lines, creditsLine)
        if creditsLine != nil {
            appendIfPresent(&lines, overageLine(premium))
        }

        appendIfPresent(&lines, snapshotLine(label: "Chat", snapshots?["chat"], resetsAt: resetsAt))
        appendIfPresent(&lines, snapshotLine(label: "Completions", snapshots?["completions"], resetsAt: resetsAt))

        if lines.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            appendIfPresent(&lines, limitedLine(label: "Chat", remaining: limited?["chat"], total: monthly?["chat"], resetsAt: resetsAt))
            appendIfPresent(&lines, limitedLine(label: "Completions", remaining: limited?["completions"], total: monthly?["completions"], resetsAt: resetsAt))
        }

        guard !lines.isEmpty else {
            guard ProviderParse.bool(body["token_based_billing"]) == true else {
                throw ProviderError.unavailable("Copilot usage data is unavailable for this account.")
            }
            return ProviderUsage(plan: plan, lines: personalCreditsLines(premium))
        }

        return ProviderUsage(plan: plan, lines: lines)
    }

    private static func snapshotLine(label: String, _ raw: Any?, resetsAt: Date?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any] else { return nil }

        let entitlement = ProviderParse.number(snapshot["entitlement"])
        let remaining = ProviderParse.number(snapshot["remaining"])

        // Unlimited: the explicit flag, or GitHub's `-1` sentinel on entitlement/remaining. Suppress.
        if ProviderParse.bool(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        if entitlement == 0 { return nil }

        let usedPercent: Double
        if let percentRemaining = ProviderParse.number(snapshot["percent_remaining"]) {
            usedPercent = ProviderParse.clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = ProviderParse.clampPercent(100 - (remaining / entitlement) * 100)
        } else {
            return nil
        }

        return .percent(label, usedPercent, resetsAt: resetsAt, periodMs: periodMs)
    }

    private static func personalCreditsLines(_ raw: Any?) -> [MetricLine] {
        guard let snapshot = raw as? [String: Any],
              let creditsUsed = ProviderParse.number(snapshot["credits_used"]),
              creditsUsed > 0
        else {
            return []
        }
        return [.values(label: "Credits", values: [MetricValue(number: creditsUsed, kind: .count)])]
    }

    private static func overageLine(_ raw: Any?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any],
              ProviderParse.bool(snapshot["overage_permitted"]) == true
        else {
            return nil
        }
        let overage = max(0, ProviderParse.number(snapshot["overage_count"]) ?? 0)
        return .values(label: "Extra Usage", values: [MetricValue(number: overage, kind: .count)])
    }

    private static func limitedLine(label: String, remaining: Any?, total: Any?, resetsAt: Date?) -> MetricLine? {
        guard let total = ProviderParse.number(total), total > 0,
              let remaining = ProviderParse.number(remaining)
        else {
            return nil
        }
        let used = max(0, total - remaining)
        return .percent(label, ProviderParse.clampPercent((used / total) * 100), resetsAt: resetsAt, periodMs: periodMs)
    }

    private static func appendIfPresent(_ lines: inout [MetricLine], _ line: MetricLine?) {
        if let line { lines.append(line) }
    }

    private static func planLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.titleCased(separator: { $0 == "_" || $0 == " " || $0 == "-" }, lowercasingTail: true)
    }

    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = OpenUsageISO8601.date(from: raw) { return date }
        return dayOnlyFormatter.date(from: raw)
    }

    private nonisolated(unsafe) static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
