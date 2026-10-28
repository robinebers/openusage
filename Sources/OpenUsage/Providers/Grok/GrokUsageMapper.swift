import Foundation

enum GrokUsageMapper {
    /// Map the credits-format billing response into the provider's remote lines: the Weekly meter
    /// plus the pay-as-you-go badge. The Weekly line is omitted (the tile reads "No data") when the
    /// account's current period isn't weekly — an account still on the old monthly-only billing has
    /// no weekly pool, and mislabeling its monthly percent would be worse than an honest blank.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> ProviderUsage {
        try ProviderError.requireSuccess(response, kind: .grok)
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            let used = ProviderParse.clampPercent(config.usedPercent)
            lines.append(.percent("Weekly limit", used, resetsAt: config.periodEnd, periodMs: config.periodDurationMs))
        }
        // A missing `onDemandCap` means no pay-as-you-go (proto-JSON also drops a 0 cap) → the
        // Disabled badge, same as a present cap of 0.
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled"
        ))
        return ProviderUsage(lines: lines)
    }

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
