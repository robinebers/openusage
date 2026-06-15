import Foundation

struct DevinMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum DevinUsageMapper {
    static let dayPeriodMs = MetricPeriod.dayMs
    static let weekPeriodMs = MetricPeriod.weekMs

    static func mapUserStatusResponse(_ response: HTTPResponse) throws -> DevinMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body),
              let userStatus = body["userStatus"] as? [String: Any]
        else {
            throw DevinUsageError.invalidResponse
        }
        return try mapUserStatus(userStatus)
    }

    static func mapUserStatus(_ userStatus: [String: Any]) throws -> DevinMappedUsage {
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = readTrimmedString(planInfo["planName"]) ?? "Unknown"
        let hideDailyQuota = readBool(planInfo["hideDailyQuota"]) == true

        let dailyRemaining = ProviderParse.number(planStatus["dailyQuotaRemainingPercent"])
        let weeklyRemaining = ProviderParse.number(planStatus["weeklyQuotaRemainingPercent"])
        let dailyReset = hideDailyQuota ? nil : unixSecondsToDate(planStatus["dailyQuotaResetAtUnix"])
        let weeklyReset = unixSecondsToDate(planStatus["weeklyQuotaResetAtUnix"])
        let extraUsageBalance = formatDollarsFromMicros(planStatus["overageBalanceMicros"])

        var lines: [MetricLine] = []
        if !hideDailyQuota,
           let dailyRemaining {
            lines.append(quotaLine(
                label: "Daily quota",
                remaining: dailyRemaining,
                resetsAt: dailyReset,
                periodDurationMs: dayPeriodMs
            ))
        }

        if let weeklyRemaining {
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: weeklyRemaining,
                resetsAt: weeklyReset,
                periodDurationMs: weekPeriodMs
            ))
        } else if hideDailyQuota,
                  let dailyRemaining {
            // No weekly quota in the response: surface the (hidden) daily quota in the Weekly row so
            // the tile stays meaningful. Still flipped from remaining→used, just like every quota row.
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: dailyRemaining,
                resetsAt: weeklyReset,
                periodDurationMs: weekPeriodMs
            ))
        }

        if let extraUsageBalance {
            lines.append(.text(label: "Extra usage balance", value: extraUsageBalance))
        }

        guard !lines.isEmpty else {
            throw DevinUsageError.quotaUnavailable
        }

        return DevinMappedUsage(plan: plan, lines: lines)
    }

    /// Devin reports quota as percent *remaining*; the tile shows percent *used*, so every quota row
    /// flips `100 - remaining` (clamped) — including the weekly-from-daily fallback above.
    private static func quotaLine(label: String, remaining: Double, resetsAt: Date?, periodDurationMs: Int) -> MetricLine {
        .progress(
            label: label,
            used: ProviderParse.clampPercent(100 - remaining),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs
        )
    }

    private static func unixSecondsToDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatDollarsFromMicros(_ value: Any?) -> String? {
        guard var micros = ProviderParse.number(value) else { return nil }
        micros = max(0, micros)
        return Formatters.currency(micros / 1_000_000)
    }

    private static func readTrimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

enum DevinUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "Devin quota data unavailable. Try again later."
        }
    }
}
