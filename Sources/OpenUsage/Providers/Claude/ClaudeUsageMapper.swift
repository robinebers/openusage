import Foundation

struct ClaudeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// Provider header notice (amber triangle + tooltip) riding along with this usage, e.g. the
    /// rate-limited warning. `nil` for a clean fetch.
    var warning: String?
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
        appendScopedWeeklyLimit(body["limits"], modelName: "Fable", label: "Fable", to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)
        appendResetGrants(body["cedar_ember"], now: now, to: &lines)

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
            ],
            warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        )
    }

    /// Provider header warning (the amber triangle + tooltip) for the rate-limited state. The badge/note
    /// lines above only render when their metrics are enabled in the layout, so without this the default
    /// dashboard showed bare "No data" rows with no hint of why. Also warns the
    /// user off manual refreshes, which extend Anthropic's rate limiting.
    static func rateLimitedWarning(retryAfterSeconds: Int?) -> String {
        let base = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse."
        guard let retryText = retryAfterSeconds.map(formatRateLimitMinutes) else { return base }
        return "\(base) Retrying in ~\(retryText)."
    }

    /// Provider warning shown on the Claude header (the amber triangle + tooltip, like Z.ai's "no coding
    /// plan" notice) when the stored login can't read live usage because it lacks the `user:profile` scope
    /// (an inference-only token, e.g. from `claude setup-token`). Without it the Session / Weekly bars just
    /// read "No data" with no hint that a re-login restores them. The scanned spend tiles are unaffected
    /// and still load.
    static let missingProfileScopeWarning = "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."

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

    /// Plan label from the live profile, formatted like the stored one so the badge reads the same either
    /// way. `organization_type` arrives as `claude_max` / `claude_pro`; the `claude_` prefix is dropped so it
    /// title-cases to "Max" / "Pro". Fields the profile omits fall back to the stored login so a partial
    /// payload still corrects whatever it does report. `nil` when the profile carries no organization —
    /// the caller keeps the stored plan.
    static func formatLivePlan(profile: ClaudeAccountProfile, credentials: ClaudeOAuth) -> String? {
        guard let organization = profile.organization else { return nil }
        let subscriptionType = organization.organizationType.map { type in
            type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        }
        return formatPlan(
            subscriptionType: subscriptionType ?? credentials.subscriptionType,
            rateLimitTier: organization.rateLimitTier ?? credentials.rateLimitTier
        )
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

    /// A model-scoped weekly limit from the `limits` array — `kind: "weekly_scoped"` with
    /// `scope.model.display_name` naming the model (e.g. "Fable"). Anthropic moved the per-model
    /// weekly windows off the legacy top-level `seven_day_<model>` keys (which now come back null)
    /// and into this array, so each scoped row is read by display name. `percent` is 0–100.
    private static func appendScopedWeeklyLimit(_ limits: Any?, modelName: String, label: String, to lines: inout [MetricLine]) {
        guard let array = limits as? [Any] else { return }
        for entry in array {
            guard let object = entry as? [String: Any],
                  object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  model["display_name"] as? String == modelName,
                  let used = ProviderParse.number(object["percent"])
            else { continue }
            lines.append(.progress(
                label: label,
                used: used,
                limit: 100,
                format: .percent,
                resetsAt: resetDate(object["resets_at"]),
                periodDurationMs: weeklyPeriodMs
            ))
            return
        }
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

    /// Usage-limit reset grants from the `cedar_ember` block (e.g. a launch promo's "one usage-limit reset
    /// for Pro and Max"), shown read-only like Codex's reset credits: the row reads "N available" and each
    /// remaining reset's grant deadline (`ends_at`) rides along in `expiriesAt` for the resets popover. A
    /// grant with several resets left contributes one expiry per reset. Grants already past their deadline
    /// or with none left are skipped. An ineligible account (`eligible: false`) reads "0 available"; a
    /// missing or `null` block (plans outside the program) emits no row. Paused grants still count — they
    /// are owned, just not usable this instant.
    private static func appendResetGrants(_ value: Any?, now: Date, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any] else { return }
        var count = 0
        var expiries: [Date] = []
        if object["eligible"] as? Bool == true {
            for case let grant as [String: Any] in object["grants"] as? [Any] ?? [] {
                guard let left = ProviderParse.number(grant["resets_left"]), left >= 1 else { continue }
                let resets = Int(left.rounded(.down))
                let endsAt = resetDate(grant["ends_at"])
                if let endsAt, endsAt <= now { continue }
                count += resets
                if let endsAt { expiries += Array(repeating: endsAt, count: resets) }
            }
        }
        lines.append(.values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: Double(count), kind: .count, label: "available")],
            expiriesAt: expiries.sorted()
        ))
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

