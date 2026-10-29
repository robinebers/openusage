import Foundation

/// Organization-wide Copilot usage from GitHub's org billing: **Org Credits** counts the AI credits the
/// whole organization used this month (the endpoint reports no allotment, so no percentage), and
/// **Org Spend** is the dollars billed beyond the included pool.
enum CopilotOrgBillingMapper {
    /// The account's organizations from the `/copilot_internal/user` body, in GitHub's order.
    static func orgLogins(_ response: HTTPResponse) -> [String] {
        let logins = ProviderParse.jsonObject(response.body)?["organization_login_list"] as? [String] ?? []
        return logins.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }

    static func usageLines(_ response: HTTPResponse) -> [MetricLine] {
        let items = (ProviderParse.jsonObject(response.body)?["usageItems"] as? [[String: Any]] ?? []).filter { item in
            (item["product"] as? String)?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Copilot") == .orderedSame
        }
        let credits = items.reduce(0.0) { $0 + max(0, ProviderParse.number($1["grossQuantity"]) ?? 0) }
        let spend = items.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netAmount"]) ?? 0) }
        return [
            .values(label: "Org Credits", values: [MetricValue(number: credits, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
        ]
    }
}
