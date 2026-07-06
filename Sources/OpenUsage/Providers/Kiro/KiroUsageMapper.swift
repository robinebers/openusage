import Foundation

struct KiroMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum KiroUsageMapper {
    // Kiro's billing cycle is monthly.
    static let billingPeriodMs = MetricPeriod.monthMs

    static func mapUsageLimitsResponse(_ response: HTTPResponse) throws -> KiroMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw KiroUsageError.invalidResponse
        }
        return try mapUsageLimits(body)
    }

    static func mapUsageLimits(_ body: [String: Any]) throws -> KiroMappedUsage {
        // Plan / subscription info
        let subscriptionInfo = body["subscriptionInfo"] as? [String: Any] ?? [:]
        let rawTitle = (subscriptionInfo["subscriptionTitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = formatPlanTitle(rawTitle)

        // Usage breakdown list — each entry is one metered resource.
        let breakdownList = body["usageBreakdownList"] as? [[String: Any]] ?? []

        var lines: [MetricLine] = []
        for breakdown in breakdownList {
            guard let line = mapBreakdown(breakdown) else { continue }
            lines.append(line)
        }

        // Overage charges: surface if the user has incurred any.
        if let overageLine = mapOverage(subscriptionInfo: subscriptionInfo, breakdownList: breakdownList) {
            lines.append(overageLine)
        }

        guard !lines.isEmpty else {
            throw KiroUsageError.usageUnavailable
        }

        return KiroMappedUsage(plan: plan, lines: lines)
    }

    // MARK: - Private helpers

    private static func mapBreakdown(_ breakdown: [String: Any]) -> MetricLine? {
        // currentUsage and usageLimit must be numeric
        guard let used = ProviderParse.number(breakdown["currentUsage"]),
              let limit = ProviderParse.number(breakdown["usageLimit"]),
              limit > 0
        else {
            return nil
        }

        let displayName = (breakdown["displayNamePlural"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (breakdown["displayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Credits"

        // nextDateReset is a Unix timestamp (seconds since epoch)
        let resetsAt = unixTimestampToDate(breakdown["nextDateReset"])

        return .progress(
            label: displayName,
            used: used,
            limit: limit,
            format: .count(suffix: displayName.lowercased()),
            resetsAt: resetsAt,
            periodDurationMs: billingPeriodMs
        )
    }

    private static func mapOverage(subscriptionInfo: [String: Any], breakdownList: [[String: Any]]) -> MetricLine? {
        // Only surface overage if at least one breakdown has a non-zero charge
        let totalOverageCharges = breakdownList.compactMap {
            ProviderParse.number($0["overageCharges"])
        }.reduce(0, +)

        guard totalOverageCharges > 0 else { return nil }

        return .values(
            label: "Overage Charges",
            values: [MetricValue(number: totalOverageCharges, kind: .dollars)]
        )
    }

    private static func unixTimestampToDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatPlanTitle(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Convert "KIRO FREE" → "Kiro Free", "Q_DEVELOPER_STANDALONE_FREE" → "Q Developer Standalone Free"
        // Split on both spaces and underscores, capitalize each word.
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word -> String in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
