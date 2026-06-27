import Foundation

struct ClaudeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum ClaudeUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs

    static func mapUsageResponse(_ response: HTTPResponse, credentials: ClaudeOAuth, now: Date = Date()) throws -> ClaudeMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: ClaudeAuthError.tokenExpired,
            requestFailed: { ClaudeUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ClaudeUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        appendUsageWindow(body["five_hour"], label: "Session", periodDurationMs: sessionPeriodMs, to: &lines)
        appendUsageWindow(body["seven_day"], label: "Weekly", periodDurationMs: weeklyPeriodMs, to: &lines)
        appendUsageWindow(body["seven_day_sonnet"], label: "Sonnet", periodDurationMs: weeklyPeriodMs, to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)

        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: lines
        )
    }

    /// Snapshot shown when the usage endpoint rate-limits us and there is no last-good usage to fall back
    /// on (e.g. the first fetch after launch): a status badge plus the staleness note, no live bars.
    static func rateLimitedUsage(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let waitText = retryText.map { "Rate limited, retry in ~\($0)" } ?? "Rate limited, try again later"
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: [
                .badge(label: "Status", text: waitText, colorHex: "#F59E0B"),
                rateLimitedNote(retryAfterSeconds: retryAfterSeconds)
            ]
        )
    }

    /// The "live usage is rate limited" note appended to a last-good snapshot so the still-shown bars are
    /// flagged as possibly stale. Shared with `rateLimitedUsage` so the wording stays in one place.
    static func rateLimitedNote(retryAfterSeconds: Int?) -> MetricLine {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let noteText = retryText.map { "Live usage rate limited - retry in ~\($0)" } ?? "Live usage rate limited - data may be stale"
        return .text(label: "Note", value: noteText)
    }

    static func parseRetryAfterSeconds(_ response: HTTPResponse, now: Date = Date()) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSince(now))))
        }
        return nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)

        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[match])"
    }

    private static func appendUsageWindow(_ value: Any?, label: String, periodDurationMs: Int, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              let used = ProviderParse.number(object["utilization"])
        else {
            return
        }
        lines.append(.progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(object["resets_at"]),
            periodDurationMs: periodDurationMs
        ))
    }

    private static func appendExtraUsage(_ value: Any?, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = ProviderParse.number(object["used_credits"])
        else {
            return
        }

        let used = ProviderParse.centsToDollars(usedCents)
        if let limitCents = ProviderParse.number(object["monthly_limit"]), limitCents > 0 {
            lines.append(.progress(
                label: "Extra usage spent",
                used: used,
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars
            ))
        } else if used > 0 {
            // No monthly cap: an unbounded spend, carried raw so it formats through `MetricFormatter`
            // (compact like the spend tiles, e.g. "$1.2K spent") instead of a baked full-currency string.
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let date = OpenUsageISO8601.date(from: text) {
            return date
        }
        guard let number = ProviderParse.number(value), number.isFinite else {
            return nil
        }
        let milliseconds = abs(number) < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatRateLimitMinutes(_ seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        return "\(Int(ceil(Double(seconds) / 60)))m"
    }

}

private enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

