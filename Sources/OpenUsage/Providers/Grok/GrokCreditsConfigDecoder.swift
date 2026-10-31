import Foundation

struct GrokCreditsConfig: Equatable, Sendable {
    var periodType: String
    var usedPercent: Double
    var periodStart: Date
    var periodEnd: Date
    var onDemandCap: Double

    var periodDurationMs: Int {
        Int((periodEnd.timeIntervalSince(periodStart) * 1000).rounded())
    }
}

enum GrokCreditsConfigDecoder {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

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
            throw ProviderError.invalidResponse
        }

        // proto-JSON omits zero values, so an absent percent is a genuine 0% — but a present,
        // non-numeric or non-finite value is a schema change and must throw, not clamp to 0.
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = ProviderParse.number(raw), number.isFinite else {
                throw ProviderError.invalidResponse
            }
            percent = number
        } else {
            percent = 0
        }

        let onDemandCap: Double
        if let capObject = config["onDemandCap"] {
            guard let object = capObject as? [String: Any] else {
                throw ProviderError.invalidResponse
            }
            guard let cap = ProviderParse.number(object["val"] ?? 0), ProviderParse.int(cap) != nil else {
                throw ProviderError.invalidResponse
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
