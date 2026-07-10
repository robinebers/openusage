import Foundation

/// The slice of Grok's credits config OpenUsage renders: the shared-pool usage percent and the
/// period it applies to. Decoded from `GET /v1/billing?format=credits` (proto-JSON).
struct GrokCreditsConfig: Equatable, Sendable {
    /// `USAGE_PERIOD_TYPE_*` enum name; see `GrokCreditsConfigDecoder.weeklyPeriodType`.
    var periodType: String
    /// Pool usage in 0...100 (validated finite; clamping to range happens at the mapper).
    var usedPercent: Double
    var periodStart: Date
    var periodEnd: Date
    /// Pay-as-you-go cap in credits; 0 when disabled (proto-JSON also omits the field at 0).
    var onDemandCap: Double

    var periodDurationMs: Int {
        Int((periodEnd.timeIntervalSince(periodStart) * 1000).rounded())
    }
}

/// Shape observed live from `cli-chat-proxy.grok.com/v1/billing?format=credits` (2026-07-06),
/// matching what the Grok CLI logs as "billing: fetched credits config":
///
///     { "config": {
///         "creditUsagePercent": 99.0,          // proto-JSON: omitted entirely when 0
///         "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
///                            "start": "2026-07-03T04:01:09.238389+00:00",
///                            "end":   "2026-07-10T04:01:09.238389+00:00" },
///         "onDemandCap": { "val": 2500 },      // pay-as-you-go cap; 0/absent when disabled
///         "isUnifiedBillingUser": true, ... } }
///
/// The response is a proto3 message serialized as JSON, so zero-valued fields are dropped:
/// an absent `creditUsagePercent` means 0, not a schema change. Unknown fields are ignored by
/// JSON parsing naturally.
enum GrokCreditsConfigDecoder {
    /// The shared weekly pool Grok migrated unified-billing users to.
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    /// Decode the JSON response body. A missing config/period, a non-finite percent, malformed
    /// timestamps, or a period that doesn't move forward is `invalidResponse` — the server
    /// answered, but not in the shape we know.
    static func decode(responseBody: Data) throws -> GrokCreditsConfig {
        guard let body = ProviderParse.jsonObject(responseBody),
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = (period["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !periodType.isEmpty,
              let start = date(period["start"]),
              let end = date(period["end"]),
              end > start
        else {
            throw GrokUsageError.invalidResponse
        }

        // proto-JSON omits zero values, so an absent percent is a genuine 0% — but a present,
        // non-numeric or non-finite value is a schema change and must throw, not clamp to 0.
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = ProviderParse.number(raw), number.isFinite else {
                throw GrokUsageError.invalidResponse
            }
            percent = number
        } else {
            percent = 0
        }

        // Like the percent: absent means 0 (disabled), but a present non-numeric value is drift.
        let onDemandCap: Double
        if let capObject = config["onDemandCap"] {
            guard let object = capObject as? [String: Any] else {
                throw GrokUsageError.invalidResponse
            }
            guard let cap = ProviderParse.number(object["val"] ?? 0), cap.isFinite else {
                throw GrokUsageError.invalidResponse
            }
            onDemandCap = cap
        } else {
            onDemandCap = 0
        }

        return GrokCreditsConfig(
            periodType: periodType, usedPercent: percent,
            periodStart: start, periodEnd: end, onDemandCap: onDemandCap
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return OpenUsageISO8601.date(from: raw)
    }
}
