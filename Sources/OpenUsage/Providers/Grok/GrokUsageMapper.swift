import Foundation

enum GrokUsageMapper {
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> ProviderUsage {
        if response.statusCode == 412,
           (ProviderParse.jsonObject(response.body)?["error"] as? String)?.localizedCaseInsensitiveContains("no personal team") == true {
            return ProviderUsage(lines: [], notice: "Grok team accounts have no personal quota.")
        }
        try ProviderError.requireSuccess(response, kind: .grok)
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            let used = ProviderParse.clampPercent(config.usedPercent)
            lines.append(.percent("Weekly limit", used, resetsAt: config.periodEnd, periodMs: config.periodDurationMs))
        }
        if config.onDemandCap > 0 {
            let cap = MetricFormatter.number(ProviderParse.centsToDollars(config.onDemandCap), kind: .dollars, style: .row)
            lines.append(.badge(label: "Pay as you go", text: "\(cap) cap"))
        }
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
}
