import Foundation

/// Builds metric lines from the OrcaRouter billing endpoints. The usage payload is OpenAI-shape
/// (`{ "total_usage": … }`, top-level field, no `data` wrapper); the balance payload is an OrcaRouter
/// object that reports its own `unit` (USD). Each endpoint maps independently so the provider can show
/// whatever came back — the usage row and the balance rows are each usable on their own.
enum OrcaRouterUsageMapper {
    /// Total spend so far is a top-level `total_usage` on the OpenAI-shape payload.
    static func usageLine(from data: [String: Any]) -> MetricLine? {
        guard let totalUsage = ProviderParse.number(data["total_usage"]) else { return nil }
        return .values(
            label: "Total Usage",
            values: [MetricValue(number: max(0, totalUsage), kind: .dollars)]
        )
    }

    /// Balance rows from `/balance`: the funded wallet and the sum of free credits, each a dollar value.
    /// The object reports `unit: "USD"`, so the numbers are honored as-is. The wallet balance is shown
    /// raw — a negative balance (usage past the funded amount) is real data, not clamped to zero.
    static func balanceLines(from data: [String: Any]) -> [MetricLine] {
        var lines: [MetricLine] = []

        if let paid = ProviderParse.number(data["paid_balance"]) {
            lines.append(.values(
                label: "Balance",
                values: [MetricValue(number: paid, kind: .dollars)]
            ))
        }
        if let free = freeCreditTotal(data["free_credit"]) {
            lines.append(.values(
                label: "Free Credit",
                values: [MetricValue(number: max(0, free), kind: .dollars)]
            ))
        }
        return lines
    }

    /// Sum of the per-model free-credit balances, when the array is present.
    private static func freeCreditTotal(_ value: Any?) -> Double? {
        guard let entries = value as? [[String: Any]] else { return nil }
        let balances = entries.compactMap { ProviderParse.number($0["balance_usd"] ?? $0["balance"]) }
        guard !balances.isEmpty else { return nil }
        return balances.reduce(0, +)
    }
}
