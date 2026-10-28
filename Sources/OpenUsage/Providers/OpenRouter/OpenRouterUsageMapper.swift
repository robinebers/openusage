import Foundation

/// Builds metric lines from the OpenRouter `/credits` and `/key` payloads. Each endpoint maps
/// independently so the provider can show whatever came back: `/credits` carries the balance, `/key`
/// the tier and period spend, and either one failing still leaves the other's rows usable.
enum OpenRouterUsageMapper {
    /// OpenRouter wraps every payload in `{ "data": { ... } }`.
    static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    /// Balance from `/credits`. Empty when the payload carries no usable total.
    static func creditsLines(from data: [String: Any]) -> [MetricLine] {
        guard let totalUsage = ProviderParse.number(data["total_usage"]) else { return [] }
        // `total_credits` is the lifetime amount added to the account; balance is what's left of it.
        let totalCredits = max(0, ProviderParse.number(data["total_credits"]) ?? 0)
        // A real zero is shown ("$0.00 left"), never "No data".
        return [.values(
            label: "Balance",
            values: [MetricValue(number: max(0, totalCredits - max(0, totalUsage)), kind: .dollars)]
        )]
    }

    /// Period spend from `/key`, plus the tier surfaced as the plan name.
    static func keyMetrics(from data: [String: Any]) -> ProviderUsage {
        var lines: [MetricLine] = []

        // Period spend straight from the API (not a local log scan), so a real zero is a measured zero.
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
