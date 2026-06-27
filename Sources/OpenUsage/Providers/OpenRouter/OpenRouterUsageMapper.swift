import Foundation

struct OpenRouterMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes the OpenRouter `/credits` and `/key` payloads into the app's metric vocabulary.
///
/// `/credits` is required (it carries the account balance); `/key` is best-effort enrichment — its
/// tier, daily/weekly/monthly spend, and optional per-key cap are added when present, but a failed
/// `/key` call still leaves a usable balance snapshot.
enum OpenRouterUsageMapper {
    static func map(creditsResponse: HTTPResponse, keyResponse: HTTPResponse?) throws -> OpenRouterMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            creditsResponse,
            authExpired: OpenRouterAuthError.invalidKey,
            requestFailed: { OpenRouterUsageError.requestFailed($0) }
        )

        guard let creditsData = dataObject(creditsResponse.body),
              let totalUsage = ProviderParse.number(creditsData["total_usage"])
        else {
            throw OpenRouterUsageError.invalidResponse
        }

        let used = max(0, totalUsage)
        // `total_credits` is the lifetime amount added to the account; balance is what's left of it.
        let totalCredits = max(0, ProviderParse.number(creditsData["total_credits"]) ?? 0)

        var lines: [MetricLine] = []

        // Credits meter: spend against the credits purchased. Only a positive ceiling makes a meter
        // meaningful (a free/never-topped-up account reports 0 here) — those accounts still get Balance.
        if totalCredits > 0 {
            lines.append(.progress(
                label: "Credits",
                used: used,
                limit: totalCredits,
                format: .dollars
            ))
        }

        // Balance: prepaid credits remaining. A real zero is shown ("$0.00 left"), never "No data".
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: max(0, totalCredits - used), kind: .dollars)]
        ))

        let plan = appendKeyMetrics(keyResponse, into: &lines)

        return OpenRouterMappedUsage(plan: plan, lines: lines)
    }

    /// Adds the `/key`-derived rows when that best-effort call succeeded, returning the plan name (tier).
    private static func appendKeyMetrics(_ response: HTTPResponse?, into lines: inout [MetricLine]) -> String? {
        guard let response,
              (200..<300).contains(response.statusCode),
              let keyData = dataObject(response.body)
        else {
            return nil
        }

        // Period spend straight from the API (not a local log scan), so a real zero is a measured zero.
        appendSpend(keyData["usage_daily"], label: "Today", into: &lines)
        appendSpend(keyData["usage_weekly"], label: "This Week", into: &lines)
        appendSpend(keyData["usage_monthly"], label: "This Month", into: &lines)

        // Per-key spend cap, when this key is configured with one.
        if let limit = ProviderParse.number(keyData["limit"]), limit > 0 {
            lines.append(.progress(
                label: "Key Limit",
                used: max(0, ProviderParse.number(keyData["usage"]) ?? 0),
                limit: limit,
                format: .dollars
            ))
        }

        guard let isFreeTier = keyData["is_free_tier"] as? Bool else { return nil }
        return isFreeTier ? "Free tier" : "Pay as you go"
    }

    private static func appendSpend(_ value: Any?, label: String, into lines: inout [MetricLine]) {
        guard let amount = ProviderParse.number(value) else { return }
        lines.append(.values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)]))
    }

    /// OpenRouter wraps every payload in `{ "data": { ... } }`.
    private static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }
}
