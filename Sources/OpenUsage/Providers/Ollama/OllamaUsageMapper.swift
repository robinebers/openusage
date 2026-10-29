import Foundation

enum OllamaUsageMapper {
    static func map(balanceBody: Data, accountBody: Data?) throws -> ProviderUsage {
        ProviderUsage(plan: accountBody.flatMap(plan(from:)), lines: try balanceLines(balanceBody))
    }

    static func balanceLines(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body),
              let included = root["included"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let session = legacyLine(included["session"], label: "Session", periodMs: MetricPeriod.sessionMs) {
            lines.append(session)
        }
        if let weekly = legacyLine(included["weekly"], label: "Weekly", periodMs: MetricPeriod.weekMs) {
            lines.append(weekly)
        }
        if let monthly = monthlyLine(included) {
            lines.append(monthly)
        }
        guard !lines.isEmpty else { throw ProviderError.invalidResponse }

        if let purchased = purchasedLine(root["purchased"]) {
            lines.append(purchased)
        }
        return lines
    }

    /// The account's plan, title-cased for the header badge ("pro" → "Pro"), or `nil` when the body is
    /// not an account or names no plan. Called directly, ollama.com capitalizes its JSON keys (`Plan`);
    /// the local Ollama server lowercases them when it proxies the same response, so both spellings
    /// are accepted.
    static func plan(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let text = (root["Plan"] ?? root["plan"]) as? String,
              let name = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return nil }
        return name.capitalized
    }

    static func email(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let text = (root["Email"] ?? root["email"]) as? String
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func legacyLine(_ entry: Any?, label: String, periodMs: Int) -> MetricLine? {
        guard let entry = entry as? [String: Any],
              let remaining = ProviderParse.number(entry["remaining_percent"]) else { return nil }
        let resetsAt = date(entry["resets_at"])
        let used = ProviderParse.clampPercent(100 - remaining)
        return .percent(label, used, resetsAt: resetsAt, periodMs: resetsAt == nil ? nil : periodMs)
    }

    private static func monthlyLine(_ included: [String: Any]) -> MetricLine? {
        guard let allowance = ProviderParse.number(included["allowance_usd"]), allowance > 0,
              let balance = ProviderParse.number(included["balance_usd"]) else { return nil }
        let period = included["period"] as? [String: Any]
        let from = date(period?["from"])
        let until = date(period?["until"])
        var periodMs: Int?
        if let from, let until, until > from {
            periodMs = Int(until.timeIntervalSince(from) * 1000)
        }
        return .progress(
            label: "Monthly",
            used: min(allowance, max(0, allowance - balance)),
            limit: allowance,
            format: .dollars,
            resetsAt: until,
            periodDurationMs: periodMs
        )
    }

    private static func purchasedLine(_ purchased: Any?) -> MetricLine? {
        guard let purchased = purchased as? [String: Any],
              let balance = ProviderParse.number(purchased["balance_usd"]) else { return nil }
        return .values(
            label: "Purchased Credits",
            values: [MetricValue(number: max(0, balance), kind: .dollars)]
        )
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(OpenUsageISO8601.date(from:))
    }
}
