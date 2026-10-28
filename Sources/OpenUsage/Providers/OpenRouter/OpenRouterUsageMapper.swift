import Foundation

enum OpenRouterUsageMapper {
    static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    static func creditsLines(from data: [String: Any]) -> [MetricLine] {
        guard let totalUsage = ProviderParse.number(data["total_usage"]) else { return [] }
        let totalCredits = max(0, ProviderParse.number(data["total_credits"]) ?? 0)
        return [.values(
            label: "Balance",
            values: [MetricValue(number: max(0, totalCredits - max(0, totalUsage)), kind: .dollars)]
        )]
    }

    static func keyMetrics(from data: [String: Any]) -> ProviderUsage {
        var lines: [MetricLine] = []

        appendSpend(data["usage_daily"], label: "Today", into: &lines)
        appendSpend(data["usage_weekly"], label: "This Week", into: &lines)
        appendSpend(data["usage_monthly"], label: "This Month", into: &lines)

        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free" : "Pay-as-you-go" }
        return ProviderUsage(plan: plan, lines: lines)
    }

    private static func appendSpend(_ value: Any?, label: String, into lines: inout [MetricLine]) {
        guard let amount = ProviderParse.number(value) else { return }
        lines.append(.values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)]))
    }
}
