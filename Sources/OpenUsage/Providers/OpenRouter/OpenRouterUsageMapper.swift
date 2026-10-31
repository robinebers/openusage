import Foundation

/// What `/api/v1/key` says about the key that calls it. A management key cannot run inference, so its
/// own spend is always zero; the account's spend is the sum over the keys `/api/v1/keys` lists.
struct OpenRouterKey: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case management
        case standard(spend: [UsageWindow: UsageTotals])
    }

    var kind: Kind
    var plan: String?
    /// Key Limit, Budget and Free Requests, each when OpenRouter reports one.
    var lines: [MetricLine]
}

enum OpenRouterUsageMapper {
    /// Spend today, this week and this month, before any key is added.
    static let noSpend: [UsageWindow: UsageTotals] = [
        .today: .zero([.spend, .byokSpend]), .thisWeek: .zero([.spend, .byokSpend]), .thisMonth: .zero([.spend, .byokSpend])
    ]

    /// A UTC day with no activity row.
    static let quietDay = UsageDay(
        totals: .zero([.spend, .byokSpend, .requests, .tokens, .inputTokens, .cacheReadTokens, .outputTokens, .reasoningTokens]),
        byModel: [:]
    )

    static func key(_ body: Data, now: Date = Date()) throws -> OpenRouterKey {
        guard let data = dataObject(body), let isManagement = data["is_management_key"] as? Bool else {
            throw ProviderError.invalidResponse
        }
        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free" : "Pay-as-you-go" }
        let lines = try [keyLimitLine(data, now: now), budgetLine(data, now: now), freeRequestsLine(data, now: now)]
        return try OpenRouterKey(kind: isManagement ? .management : .standard(spend: spend(data)), plan: plan, lines: lines.compactMap { $0 })
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

    static func keysPage(_ body: Data) throws -> [[UsageWindow: UsageTotals]] {
        guard let keys = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        return try keys.map(spend)
    }

    /// `/api/v1/activity`'s rows summed per UTC day and per model; nil when any row is malformed.
    static func activityDays(_ body: Data) -> [Date: UsageDay]? {
        guard let rows = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else { return nil }
        var days: [Date: UsageDay] = [:]
        for row in rows {
            guard let date = (row["date"] as? String).flatMap({ OpenUsageISO8601.date(from: "\($0)T00:00:00Z") }),
                  let model = row["model"] as? String,
                  let totals = activityTotals(row) else { return nil }
            let day = days[date] ?? quietDay
            var models = day.byModel ?? [:]
            models[model] = models[model].map { $0.adding(totals) } ?? totals
            days[date] = UsageDay(totals: day.totals.adding(totals), byModel: models)
        }
        return days
    }

    private static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    /// What a key spent today, this week and this month, with what it spent on BYOK when reported.
    private static func spend(_ key: [String: Any]) throws -> [UsageWindow: UsageTotals] {
        let periods: [(UsageWindow, String)] = [(.today, "daily"), (.thisWeek, "weekly"), (.thisMonth, "monthly")]
        return Dictionary(uniqueKeysWithValues: try periods.map { window, period in
            guard let spend = ProviderParse.number(key["usage_\(period)"]) else { throw ProviderError.invalidResponse }
            var totals = UsageTotals(values: [.spend: max(0, spend)])
            totals.values[.byokSpend] = ProviderParse.number(key["byok_usage_\(period)"]).map { max(0, $0) }
            return (window, totals)
        })
    }

    /// Prompt tokens include cached ones and completion tokens include reasoning, so tokens are the two summed.
    private static func activityTotals(_ row: [String: Any]) -> UsageTotals? {
        let fields: [(UsageMeasure, String)] = [
            (.spend, "usage"), (.byokSpend, "byok_usage_inference"), (.requests, "requests"), (.inputTokens, "prompt_tokens"),
            (.cacheReadTokens, "cached_tokens"), (.outputTokens, "completion_tokens"), (.reasoningTokens, "reasoning_tokens")
        ]
        var totals = UsageTotals()
        for (measure, field) in fields {
            guard let value = row[field] else { continue }
            guard let number = ProviderParse.number(value), number >= 0 else { return nil }
            totals.values[measure] = number
        }
        guard totals[.spend] != nil, totals[.requests] != nil,
              let prompt = totals[.inputTokens], let completion = totals[.outputTokens] else { return nil }
        totals.values[.tokens] = prompt + completion
        return totals
    }

    private static func keyLimitLine(_ key: [String: Any], now: Date) throws -> MetricLine? {
        guard let limit = ProviderParse.number(key["limit"]), limit > 0 else { return nil }
        guard let remaining = ProviderParse.number(key["limit_remaining"]) else { throw ProviderError.invalidResponse }
        return progress("Key Limit", used: max(0, limit - max(0, remaining)), limit: limit, format: .dollars,
                        resets: key["limit_reset"] as? String, now: now)
    }

    /// The budget OpenRouter checks this key's requests against.
    private static func budgetLine(_ key: [String: Any], now: Date) throws -> MetricLine? {
        guard let budget = key["effective_budget"] as? [String: Any],
              let limit = ProviderParse.number(budget["limit_usd"]), limit > 0 else { return nil }
        guard let spend = ProviderParse.number(budget["spend_usd"]) else { throw ProviderError.invalidResponse }
        return progress("Budget", used: max(0, spend), limit: limit, format: .dollars,
                        resets: budget["reset_interval"] as? String, now: now)
    }

    /// The account's free-model requests for the UTC day.
    private static func freeRequestsLine(_ key: [String: Any], now: Date) throws -> MetricLine? {
        guard let free = key["free_model_daily_requests"] as? [String: Any],
              let limit = ProviderParse.number(free["limit"]), limit > 0 else { return nil }
        guard let used = ProviderParse.number(free["used"]) else { throw ProviderError.invalidResponse }
        return progress("Free Requests", used: max(0, used), limit: limit, format: .count(suffix: "requests"),
                        resets: "daily", now: now)
    }

    private static func progress(
        _ label: String, used: Double, limit: Double, format: ProgressFormat, resets period: String?, now: Date
    ) -> MetricLine {
        let window = period.flatMap { resetPeriods[$0] }.flatMap { utc.dateInterval(of: $0, for: now) }
        return .progress(label: label, used: used, limit: limit, format: format, resetsAt: window?.end,
                         periodDurationMs: window.map { Int($0.duration * 1000) })
    }

    private static let resetPeriods: [String: Calendar.Component] = ["daily": .day, "weekly": .weekOfYear, "monthly": .month]

    /// OpenRouter's days, limits and budgets reset at midnight UTC, and its weeks start on Monday.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
