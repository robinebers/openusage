import Foundation

enum DevinUsageMapper {
    static func map(_ body: Data) throws -> ProviderUsage {
        guard let userStatus = ProviderParse.jsonObject(body)?["userStatus"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let daily = try quota(planStatus, remaining: "dailyQuotaRemainingPercent", reset: "dailyQuotaResetAtUnix")
        let weekly = try quota(planStatus, remaining: "weeklyQuotaRemainingPercent", reset: "weeklyQuotaResetAtUnix")

        var lines: [MetricLine] = []
        if ProviderParse.bool(planInfo["hideDailyQuota"]) == true {
            // A plan that hides its daily quota still meters it. With no weekly window, the Weekly row
            // carries it.
            if let shown = weekly ?? daily.map({ (remaining: $0.remaining, resetsAt: nil) }) {
                lines.append(quotaLine("Weekly quota", shown, periodMs: MetricPeriod.weekMs))
            }
        } else {
            if let daily { lines.append(quotaLine("Daily quota", daily, periodMs: MetricPeriod.dayMs)) }
            if let weekly { lines.append(quotaLine("Weekly quota", weekly, periodMs: MetricPeriod.weekMs)) }
        }
        if let micros = ProviderParse.number(planStatus["overageBalanceMicros"]) {
            lines.append(.values(label: "Extra usage balance", values: [MetricValue(number: max(0, micros) / 1_000_000, kind: .dollars)]))
        }
        guard !lines.isEmpty else {
            throw ProviderError.unavailable("Devin reports no quota for this account.")
        }
        let plan = (planInfo["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return ProviderUsage(plan: plan, lines: lines)
    }

    /// Devin reports the share of a quota left. Proto3 JSON omits a zero, so a window with a reset and
    /// no share has none left. A share present but unreadable is a changed schema, not an empty quota.
    private static func quota(_ planStatus: [String: Any], remaining key: String, reset resetKey: String) throws -> (remaining: Double, resetsAt: Date?)? {
        let resetsAt = ProviderParse.number(planStatus[resetKey]).map { Date(timeIntervalSince1970: $0) }
        guard let value = planStatus[key] else { return resetsAt.map { (0, $0) } }
        guard let remaining = ProviderParse.number(value) else { throw ProviderError.invalidResponse }
        return (remaining, resetsAt)
    }

    private static func quotaLine(_ label: String, _ quota: (remaining: Double, resetsAt: Date?), periodMs: Int) -> MetricLine {
        .percent(label, ProviderParse.clampPercent(100 - quota.remaining), resetsAt: quota.resetsAt, periodMs: periodMs)
    }
}
