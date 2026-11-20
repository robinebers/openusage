import Foundation

/// The Account object: `cash_credits` is the account's credit in USD, as a decimal string.
enum PlivoUsageMapper {
    static func map(_ body: Data) throws -> ProviderUsage {
        guard let account = ProviderParse.jsonObject(body), let credits = ProviderParse.number(account["cash_credits"]) else {
            throw ProviderError.invalidResponse
        }
        let plan = (account["billing_mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).capitalized.nilIfEmpty
        return ProviderUsage(plan: plan, lines: [.values(label: "Credits", values: [MetricValue(number: credits, kind: .dollars)])])
    }
}
