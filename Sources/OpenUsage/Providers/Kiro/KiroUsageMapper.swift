import Foundation

struct KiroMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Builds metric lines from the Kiro `getUsageLimits` API response. The response carries a
/// `usageBreakdownList` of credit pools (each with `currentUsage`, `usageLimit`, `resetDate`), an
/// optional `freeTrialUsage` / `bonuses` bonus pool, a `subscriptionInfo.subscriptionTitle` plan name,
/// and an `overageConfiguration.overageStatus` badge.
///
/// The mapper is pure (no I/O) so it tests cleanly against sample payloads, exactly like the other
/// providers' mappers.
enum KiroUsageMapper {
    /// `(plan, lines)` from the `getUsageLimits` response body.
    static func map(_ body: Data) throws -> KiroMappedUsage {
        guard let root = ProviderParse.jsonObject(body) else {
            throw KiroUsageError.invalidResponse
        }

        let plan = readTrimmedString(root["subscriptionInfo"], key: "subscriptionTitle")
        let nextReset = parseResetDate(root["nextDateReset"])

        var lines: [MetricLine] = []

        // Primary credit pool from usageBreakdownList. Only map CREDIT-type entries so we don't
        // mislabel other breakdown types (chat/completions) as credits.
        if let breakdownList = root["usageBreakdownList"] as? [[String: Any]] {
            for entry in breakdownList {
                guard (entry["type"] as? String)?.uppercased() == "CREDIT" else { continue }
                if let line = try? creditLine(from: entry, resetDate: nextReset) {
                    lines.append(line)
                }
            }
        }

        // Bonus / free-trial credits.
        if let freeTrial = root["freeTrialUsage"] as? [String: Any],
           let line = try? bonusLine(from: freeTrial, label: "Bonus Credits", resetDate: nil) {
            lines.append(line)
        }

        // Overage status badge.
        if let overageConfig = root["overageConfiguration"] as? [String: Any],
           let status = readTrimmedString(overageConfig, key: "overageStatus") {
            lines.append(.badge(label: "Overages", text: status))
        }

        guard !lines.isEmpty else {
            throw KiroUsageError.quotaUnavailable
        }

        return KiroMappedUsage(plan: plan, lines: lines)
    }

    // MARK: - Private

    /// A credit pool entry from `usageBreakdownList` → a bounded count meter.
    private static func creditLine(from entry: [String: Any], resetDate: Date?) throws -> MetricLine {
        let used = ProviderParse.number(entry["currentUsage"]) ?? 0
        let limit = ProviderParse.number(entry["usageLimit"])
        let reset = parseResetDate(entry["resetDate"]) ?? resetDate

        guard let limit, limit > 0 else {
            throw KiroUsageError.invalidResponse
        }

        return .progress(
            label: "Credits",
            used: used,
            limit: limit,
            format: .count(suffix: "credits"),
            resetsAt: reset,
            periodDurationMs: MetricPeriod.monthMs
        )
    }

    /// A bonus/free-trial pool → a bounded count meter with its own reset/expiry.
    private static func bonusLine(from entry: [String: Any], label: String, resetDate: Date?) throws -> MetricLine {
        let used = ProviderParse.number(entry["currentUsage"]) ?? 0
        let limit = ProviderParse.number(entry["usageLimit"])
        let reset = parseResetDate(entry["expiryDate"]) ?? resetDate

        guard let limit, limit > 0 else {
            throw KiroUsageError.invalidResponse
        }

        return .progress(
            label: label,
            used: used,
            limit: limit,
            format: .count(suffix: "credits"),
            resetsAt: reset,
            periodDurationMs: MetricPeriod.monthMs
        )
    }

    /// Parse an ISO 8601 date string (e.g. "2026-05-01T00:00:00.000Z") or a Unix epoch value. The
    /// Kiro API has used both string and numeric timestamps across versions, so the parser accepts both
    /// seconds and milliseconds: values above 1 trillion are treated as milliseconds.
    private static func parseResetDate(_ value: Any?) -> Date? {
        if let numeric = ProviderParse.number(value), numeric > 0 {
            let isMilliseconds = numeric > 1_000_000_000_000
            let seconds = isMilliseconds ? numeric / 1000 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String {
            return OpenUsageISO8601.date(from: string)
        }
        return nil
    }

    private static func readTrimmedString(_ value: Any?, key: String) -> String? {
        guard let dict = value as? [String: Any],
              let string = dict[key] as? String
        else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
