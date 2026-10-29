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

    /// `nil` for a report that isn't GitHub's shape, so it never shows as zero usage.
    static func usageLines(_ response: HTTPResponse) -> [MetricLine]? {
        guard let items = ProviderParse.jsonObject(response.body)?["usageItems"] as? [[String: Any]] else { return nil }
        var credits = 0.0
        var spend = 0.0
        for item in items
        where (item["product"] as? String)?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Copilot") == .orderedSame {
            guard let quantity = ProviderParse.number(item["grossQuantity"]), let amount = ProviderParse.number(item["netAmount"]) else {
                return nil
            }
            credits += max(0, quantity)
            spend += max(0, amount)
        }
        return [
            .values(label: "Org Credits", values: [MetricValue(number: credits, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
        ]
    }
}
