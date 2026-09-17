import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

enum GrokUsageMapper {
    /// Map the credits-format billing response into the provider's remote lines: the Weekly meter
    /// plus the pay-as-you-go badge. The Weekly line is omitted (the tile reads "No data") when the
    /// account's current period isn't weekly — an account still on the old monthly-only billing has
    /// no weekly pool, and mislabeling its monthly percent would be worse than an honest blank.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            lines.append(.progress(
                label: "Weekly limit",
                used: ProviderParse.clampPercent(config.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: config.periodEnd,
                periodDurationMs: config.periodDurationMs
            ))
        }
        // A missing `onDemandCap` means no pay-as-you-go (proto-JSON also drops a 0 cap) → the
        // Disabled badge, same as a present cap of 0.
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled",
            colorHex: config.onDemandCap > 0 ? "#22c55e" : "#a3a3a3"
        ))
        return GrokMappedUsage(lines: lines)
    }

    /// HTTP 412 with this phrase is Grok's "this principal is a team, not a personal team"
    /// signal from `GET /v1/billing?format=credits`. Auth is fine; the weekly pool and
    /// pay-as-you-go cap simply aren't on this surface. Other 412s stay hard failures.
    static func isTeamBillingUnavailable(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 412 else { return false }
        guard let text = String(data: response.body, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("no personal team")
    }

    /// Provider header warning (the amber triangle) when the credits endpoint refuses a team
    /// principal. Weekly / Extra Usage stay "No data"; local spend tiles still load.
    static let teamBillingUnavailableWarning =
        "Weekly usage isn't available for team accounts. Spend below is still from your Grok logs."

    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatUnits(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
