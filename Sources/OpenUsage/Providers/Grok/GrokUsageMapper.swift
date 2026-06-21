import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

enum GrokUsageMapper {
    static func mapBillingResponse(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        guard let body = ProviderParse.jsonObject(response.body),
              let config = body["config"] as? [String: Any],
              let usedUnits = unitsValue(config["used"]),
              let limitUnits = unitsValue(config["monthlyLimit"]),
              limitUnits > 0,
              let resetsAt = resetDate(config["billingPeriodEnd"])
        else {
            throw GrokUsageError.invalidResponse
        }

        // A SuperGrok account with no pay-as-you-go has no `onDemandCap` field at all. Treat a
        // missing/non-numeric cap as 0 → the "Disabled" badge below, instead of failing the whole
        // guard and surfacing a misleading "Grok billing response changed." A present cap of 0
        // already mapped to Disabled and still does.
        // NOTE: free-tier accounts (monthlyLimit == 0) still throw `invalidResponse` here — that
        // payload shape is unconfirmed; revisit with a real sample before relaxing `limitUnits > 0`.
        let onDemandCapUnits = unitsValue(config["onDemandCap"]) ?? 0

        let usedPercent = ProviderParse.clampPercent((usedUnits / limitUnits) * 100)
        return GrokMappedUsage(lines: [
            .progress(
                label: "Credits used",
                used: usedPercent,
                limit: 100,
                format: .percent,
                resetsAt: resetsAt
            ),
            .badge(
                label: "Pay as you go",
                text: onDemandCapUnits > 0 ? "\(formatUnits(onDemandCapUnits)) cap" : "Disabled",
                colorHex: onDemandCapUnits > 0 ? "#22c55e" : "#a3a3a3"
            )
        ])
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

    private static func unitsValue(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any],
              let number = ProviderParse.number(object["val"])
        else {
            return nil
        }
        return number.isFinite ? number : nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return OpenUsageISO8601.date(from: raw)
    }

    private static func formatUnits(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
