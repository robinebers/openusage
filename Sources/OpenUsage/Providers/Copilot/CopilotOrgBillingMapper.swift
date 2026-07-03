import Foundation

/// Normalizes GitHub organization billing responses into org-level Copilot meters. The billing usage
/// summary (`/orgs/{org}/settings/billing/usage/summary`) reports month-to-date usage per product; the
/// Copilot AI-credit items become **Org Credits** (credits consumed this month, an unbounded count — the
/// endpoint exposes no allotment, so no percentage is fabricated) and **Org Spend** (dollars actually
/// billed beyond included credits). Both are organization-wide totals, not the individual seat's usage —
/// GitHub doesn't expose per-seat numbers for org-managed Copilot.
enum CopilotOrgBillingMapper {
    /// Org slugs from a `/user/orgs` response, in GitHub's order. Empty for a garbled body.
    static func orgLogins(_ response: HTTPResponse) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            (entry["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// Metric lines from a billing usage summary, or `nil` when the summary carries no Copilot AI-credit
    /// items (the org doesn't use Copilot credits — callers keep probing other orgs). Only items whose
    /// `unitType` is credit-based (`ai-units` / `ai-credits`) are counted, so seat-fee line items with
    /// other units can't pollute the totals.
    static func usageLines(_ response: HTTPResponse) -> [MetricLine]? {
        guard let body = ProviderParse.jsonObject(response.body) else { return nil }
        return usageLines(body: body)
    }

    static func usageLines(body: [String: Any]) -> [MetricLine]? {
        guard let items = body["usageItems"] as? [[String: Any]] else { return nil }

        let creditItems = items.filter { item in
            isCopilot(item["product"]) && isCreditUnit(item["unitType"])
        }
        guard !creditItems.isEmpty else { return nil }

        let credits = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["grossQuantity"]) ?? 0) }
        let spend = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netAmount"]) ?? 0) }

        return [
            .values(label: "Org Credits", values: [MetricValue(number: credits, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
        ]
    }

    private static func isCopilot(_ value: Any?) -> Bool {
        guard let product = value as? String else { return false }
        return product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copilot"
    }

    private static func isCreditUnit(_ value: Any?) -> Bool {
        guard let unit = value as? String else { return false }
        let normalized = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ai-units" || normalized == "ai-credits"
    }
}
