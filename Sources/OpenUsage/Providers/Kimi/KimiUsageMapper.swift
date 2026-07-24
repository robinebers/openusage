import Foundation

struct KimiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes the Kimi Code quota payload into metric lines.
///
/// The payload carries two pools: `usage` is the 7-day subscription quota, and `limits` is a list of rate
/// windows of which the 5-hour rolling one is what the CLI shows. Both are reported as percentages with
/// their numbers encoded as JSON *strings* (`"100"`, `"41"`), which `ProviderParse.number` coerces.
enum KimiUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs
    static let sessionLabel = "Session"
    static let weeklyLabel = "Weekly"

    static func mapUsageResponse(_ response: HTTPResponse) throws -> KimiMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw KimiUsageError.invalidResponse
        }
        return try mapUsage(body)
    }

    static func mapUsage(_ body: [String: Any]) throws -> KimiMappedUsage {
        var lines: [MetricLine] = []
        if let session = sessionLine(body["limits"]) {
            lines.append(session)
        }
        if let weekly = quotaLine(
            body["usage"] as? [String: Any],
            label: weeklyLabel,
            periodDurationMs: weeklyPeriodMs
        ) {
            lines.append(weekly)
        }

        guard !lines.isEmpty else {
            throw KimiUsageError.quotaUnavailable
        }
        return KimiMappedUsage(plan: plan(body), lines: lines)
    }

    /// The 5-hour rolling rate window from `limits`. Entries are keyed only by their window duration, so
    /// the one matching a 5-hour period becomes the session tile. Anything else is logged rather than
    /// dropped silently — Moonshot documents a 7-day rate window that isn't in the payload today, and if
    /// it appears we want it in the log instead of vanishing.
    private static func sessionLine(_ value: Any?) -> MetricLine? {
        guard let entries = value as? [[String: Any]] else { return nil }
        var session: MetricLine?
        for entry in entries {
            let detail = entry["detail"] as? [String: Any] ?? entry
            let periodMs = windowDurationMs(entry["window"] as? [String: Any])
            if periodMs == sessionPeriodMs, session == nil {
                session = quotaLine(detail, label: sessionLabel, periodDurationMs: sessionPeriodMs)
                continue
            }
            AppLog.warn(
                LogTag.plugin("kimi"),
                "unmapped rate window (durationMs=\(periodMs.map(String.init) ?? "unknown"))"
            )
        }
        return session
    }

    /// A percent meter from one `{limit, used, remaining, resetTime}` block.
    ///
    /// Kimi normalizes these pools to `limit: 100`, but the ratio is taken against the reported `limit`
    /// rather than assuming 100 so a future change of scale can't silently misreport the meter. A present
    /// `used` wins; otherwise it's derived from `limit - remaining` — the live 5-hour window carries `used`
    /// with no `remaining`, and the weekly pool carries both.
    private static func quotaLine(
        _ detail: [String: Any]?,
        label: String,
        periodDurationMs: Int
    ) -> MetricLine? {
        guard let detail,
              let limit = ProviderParse.number(detail["limit"]),
              limit > 0
        else {
            return nil
        }

        let rawUsed: Double
        if let used = ProviderParse.number(detail["used"]) {
            rawUsed = used
        } else if let remaining = ProviderParse.number(detail["remaining"]) {
            rawUsed = limit - remaining
        } else {
            return nil
        }

        return .progress(
            label: label,
            used: ProviderParse.clampPercent(rawUsed / limit * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetDate(detail["resetTime"]),
            periodDurationMs: periodDurationMs
        )
    }

    /// `{"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}` → milliseconds. The unit is matched by substring
    /// because the wire format spells it as a prefixed enum.
    private static func windowDurationMs(_ window: [String: Any]?) -> Int? {
        guard let window,
              let duration = ProviderParse.number(window["duration"]),
              duration > 0
        else {
            return nil
        }
        let unit = (window["timeUnit"] as? String)?.uppercased() ?? ""
        let multiplier: Double
        if unit.contains("SECOND") {
            multiplier = 1000
        } else if unit.contains("MINUTE") {
            multiplier = 60 * 1000
        } else if unit.contains("HOUR") {
            multiplier = 60 * 60 * 1000
        } else if unit.contains("DAY") {
            multiplier = 24 * 60 * 60 * 1000
        } else {
            return nil
        }
        return Int(duration * multiplier)
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        return OpenUsageISO8601.date(from: raw)
    }

    /// `user.membership.level` is a prefixed enum string (`LEVEL_INTERMEDIATE`). The prefix is stripped and
    /// the rest title-cased rather than mapped onto Moonshot's marketing tier names (Adagio, Moderato,
    /// Allegretto, …): the two vocabularies don't line up one-to-one, and a wrong guess would label
    /// someone's card with a plan they aren't on.
    private static func plan(_ body: [String: Any]) -> String? {
        guard let user = body["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = (membership["level"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        let name = level.hasPrefix("LEVEL_") ? String(level.dropFirst("LEVEL_".count)) : level
        return name.nilIfEmpty?.titleCased(separator: { $0 == "_" || $0 == "-" }, lowercasingTail: true)
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .quotaUnavailable:
            return "Kimi quota data unavailable. Try again later."
        }
    }
}
