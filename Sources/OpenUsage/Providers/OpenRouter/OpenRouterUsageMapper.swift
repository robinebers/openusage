import Foundation

/// What `/api/v1/key` says about the key that calls it. A management key cannot run inference, so its
/// own spend is always zero; the account's spend is the sum over the keys `/api/v1/keys` lists.
struct OpenRouterKey: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case management
        case standard([MetricLine])
    }

    var kind: Kind
    var plan: String?
}

struct OpenRouterSpend: Equatable, Sendable {
    var today: Double
    var week: Double
    var month: Double

    static let zero = OpenRouterSpend(today: 0, week: 0, month: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(today: lhs.today + rhs.today, week: lhs.week + rhs.week, month: lhs.month + rhs.month)
    }
}

enum OpenRouterUsageMapper {
    static func key(_ body: Data, now: Date = Date()) throws -> OpenRouterKey {
        guard let data = dataObject(body), let isManagement = data["is_management_key"] as? Bool else {
            throw ProviderError.invalidResponse
        }
        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free" : "Pay-as-you-go" }
        if isManagement { return OpenRouterKey(kind: .management, plan: plan) }
        var lines = spendLines(try spend(data))
        if let keyLimit = try keyLimitLine(data, now: now) { lines.append(keyLimit) }
        return OpenRouterKey(kind: .standard(lines), plan: plan)
    }

    static func creditsLines(_ body: Data) throws -> [MetricLine] {
        guard let data = dataObject(body),
              let totalCredits = ProviderParse.number(data["total_credits"]),
              let totalUsage = ProviderParse.number(data["total_usage"]) else {
            throw ProviderError.invalidResponse
        }
        let credits = max(0, totalCredits)
        let used = max(0, totalUsage)
        let balance = MetricLine.values(label: "Balance", values: [MetricValue(number: max(0, credits - used), kind: .dollars)])
        guard credits > 0 else { return [balance] }
        return [.progress(label: "Credits", used: used, limit: credits, format: .dollars), balance]
    }

    static func keysPage(_ body: Data) throws -> [OpenRouterSpend] {
        guard let keys = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        return try keys.map(spend)
    }

    static func spendLines(_ spend: OpenRouterSpend) -> [MetricLine] {
        [("Today", spend.today), ("This Week", spend.week), ("This Month", spend.month)].map { label, amount in
            .values(label: label, values: [MetricValue(number: amount, kind: .dollars)])
        }
    }

    private static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    private static func spend(_ key: [String: Any]) throws -> OpenRouterSpend {
        guard let today = ProviderParse.number(key["usage_daily"]),
              let week = ProviderParse.number(key["usage_weekly"]),
              let month = ProviderParse.number(key["usage_monthly"]) else {
            throw ProviderError.invalidResponse
        }
        return OpenRouterSpend(today: max(0, today), week: max(0, week), month: max(0, month))
    }

    private static func keyLimitLine(_ key: [String: Any], now: Date) throws -> MetricLine? {
        guard let limit = ProviderParse.number(key["limit"]), limit > 0 else { return nil }
        guard let remaining = ProviderParse.number(key["limit_remaining"]) else { throw ProviderError.invalidResponse }
        let window = (key["limit_reset"] as? String).flatMap { resetPeriods[$0] }.flatMap { utc.dateInterval(of: $0, for: now) }
        return .progress(
            label: "Key Limit",
            used: max(0, limit - max(0, remaining)),
            limit: limit,
            format: .dollars,
            resetsAt: window?.end,
            periodDurationMs: window.map { Int($0.duration * 1000) }
        )
    }

    private static let resetPeriods: [String: Calendar.Component] = ["daily": .day, "weekly": .weekOfYear, "monthly": .month]

    /// OpenRouter resets a key's limit at midnight UTC, and its weeks start on Monday.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        return calendar
    }()
}
