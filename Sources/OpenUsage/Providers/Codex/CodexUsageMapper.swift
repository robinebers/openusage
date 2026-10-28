import Foundation

struct CodexMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CodexUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs
    static func mapUsageResponse(
        _ response: HTTPResponse,
        resetCredits: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> CodexMappedUsage {
        try ProviderError.requireSuccess(response, kind: .codex)

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }

        var lines: [MetricLine] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        lines.append(contentsOf: classifiedWindowLines(
            rateLimit: rateLimit,
            labels: (session: "Session", weekly: "Weekly"),
            headerPercents: (
                primary: ProviderParse.number(response.header("x-codex-primary-used-percent")),
                secondary: ProviderParse.number(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        ))

        // Model-specific limits (e.g. GPT-5.3-Codex-Spark) ride in a separate `additional_rate_limits`
        // array, each entry reusing the primary/secondary window shape. Surfaced as their own Spark /
        // Spark Weekly meters.
        lines.append(contentsOf: sparkLines(body: body, now: now))

        // On-demand rate-limit reset credits. The row reads "2 available" (the count is carried raw, so
        // the menu-bar tile reads the same number); each still-available credit's expiry rides along in
        // `expiriesAt` for the resets popover.
        if let resets = readResetCredits(body: body, resetCredits: resetCredits) {
            lines.append(.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: Double(resets.count), kind: .count, label: "available")],
                expiriesAt: resets.expiries
            ))
        }

        if let remaining = readCreditsRemaining(response: response, body: body) {
            lines.append(.values(label: "Credits", values: creditValues(remaining: remaining)))
        }

        // An empty response yields no usage lines for the account runtime to render.
        return CodexMappedUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
    }

    private static func progress(
        label: String,
        used: Double,
        resetWindow: [String: Any]?,
        now: Date,
        periodDurationMs: Int
    ) -> MetricLine {
        .progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(resetWindow, now: now),
            periodDurationMs: periodDurationMs
        )
    }

    /// One rate-limit window → a percent-used meter, or `nil` when `usedPercent` is absent. Resolves the
    /// window's own period (falling back to `defaultPeriodMs`) while preserving the percentage reported
    /// by Codex, so all Session/Weekly/Spark paths share one construction.
    private static func windowLine(
        label: String,
        usedPercent: Double?,
        window: [String: Any]?,
        defaultPeriodMs: Int,
        now: Date
    ) -> MetricLine? {
        guard let usedPercent else { return nil }
        let periodDurationMs = readPeriodMs(window) ?? defaultPeriodMs
        return progress(
            label: label,
            used: usedPercent,
            resetWindow: window,
            now: now,
            periodDurationMs: periodDurationMs
        )
    }

    private enum WindowKind {
        case session
        case weekly
    }

    private struct WindowCandidate {
        var window: [String: Any]
        var usedPercent: Double?
        var fallbackKind: WindowKind
    }

    /// Codex normally returns the five-hour window as `primary_window` and the weekly window as
    /// `secondary_window`, but it can move a temporarily sole weekly limit into the primary slot.
    /// Classify by the explicit duration when present; keep the historical slot mapping only as a
    /// compatibility fallback for payloads that omit or introduce an unfamiliar duration.
    private static func classifiedWindowLines(
        rateLimit: [String: Any]?,
        labels: (session: String, weekly: String),
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date
    ) -> [MetricLine] {
        let candidates = [
            windowCandidate(rateLimit?["primary_window"], headerPercent: headerPercents.primary, fallbackKind: .session),
            windowCandidate(rateLimit?["secondary_window"], headerPercent: headerPercents.secondary, fallbackKind: .weekly)
        ].compactMap { $0 }

        return [
            classifiedWindowLine(kind: .session, label: labels.session, candidates: candidates, now: now),
            classifiedWindowLine(kind: .weekly, label: labels.weekly, candidates: candidates, now: now)
        ].compactMap { $0 }
    }

    private static func windowCandidate(
        _ value: Any?,
        headerPercent: Double?,
        fallbackKind: WindowKind
    ) -> WindowCandidate? {
        guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
        return WindowCandidate(
            window: window,
            usedPercent: ProviderParse.number(window["used_percent"]) ?? headerPercent,
            fallbackKind: fallbackKind
        )
    }

    private static func classifiedWindowLine(
        kind: WindowKind,
        label: String,
        candidates: [WindowCandidate],
        now: Date
    ) -> MetricLine? {
        let exact = candidates.first { exactKind(for: $0.window) == kind }
        let fallback = candidates.first { exactKind(for: $0.window) == nil && $0.fallbackKind == kind }
        guard let candidate = exact ?? fallback else { return nil }
        let defaultPeriodMs = kind == .session ? sessionPeriodMs : weeklyPeriodMs
        return windowLine(
            label: label,
            usedPercent: candidate.usedPercent,
            window: candidate.window,
            defaultPeriodMs: defaultPeriodMs,
            now: now
        )
    }

    private static func exactKind(for window: [String: Any]) -> WindowKind? {
        guard let periodMs = readPeriodMs(window) else { return nil }
        switch periodMs {
        case sessionPeriodMs: return .session
        case weeklyPeriodMs: return .weekly
        default: return nil
        }
    }

    /// Spark (and any future model-specific) limits from `additional_rate_limits`. Each array entry is a
    /// named limit whose `rate_limit` reuses the primary (5-hour) / secondary (weekly) window shape, so
    /// the parsing mirrors the core Session/Weekly path exactly. We surface the entry whose
    /// `limit_name`/`metered_feature` names Spark as the
    /// `Spark` and `Spark Weekly` meters; a non-dictionary or null array element is skipped rather than
    /// discarding its valid siblings. Returns an empty list when the field is absent or carries no Spark
    /// entry (the common case for accounts without the limit), so those rows simply read "No data".
    private static func sparkLines(body: [String: Any], now: Date) -> [MetricLine] {
        guard let rawEntries = body["additional_rate_limits"] as? [Any] else { return [] }
        let entries = rawEntries.compactMap { $0 as? [String: Any] }
        guard let spark = entries.first(where: isSparkEntry),
              let rateLimit = spark["rate_limit"] as? [String: Any]
        else {
            return []
        }

        return classifiedWindowLines(
            rateLimit: rateLimit,
            labels: (session: "Spark", weekly: "Spark Weekly"),
            now: now
        )
    }

    /// True when an `additional_rate_limits` entry is the Spark limit — matched on either `limit_name`
    /// ("GPT-5.3-Codex-Spark") or `metered_feature`, case-insensitively, so a wording change on either
    /// field still resolves it.
    private static func isSparkEntry(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap { ($0 as? String)?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.number(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParse.number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func readPeriodMs(_ window: [String: Any]?) -> Int? {
        guard let window else { return nil }
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]) else { return nil }
        return Int(seconds * 1000)
    }

    /// Codex flex-credit balance as reported by the provider.
    static func creditValues(remaining: Double) -> [MetricValue] {
        let credits = max(0, Int(remaining.rounded(.down)))
        return [MetricValue(number: Double(credits), kind: .count, label: "credits")]
    }

    /// On-demand reset credits: the floored available count plus each still-available credit's expiry,
    /// sorted soonest-first. Prefers the dedicated `/rate-limit-reset-credits` payload (the only source
    /// that carries the per-credit expiry list) and falls back to the usage body's embedded
    /// `rate_limit_reset_credits` object (count only) when that fetch was unavailable. A missing, null, or
    /// non-numeric count skips the row entirely.
    static func readResetCredits(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> (count: Int, expiries: [Date])? {
        guard let source = resetCreditsSource(body: body, resetCredits: resetCredits),
              let count = ProviderParse.number(source["available_count"]), count >= 0
        else {
            return nil
        }
        return (Int(count.rounded(.down)), availableResetCredits(in: source).compactMap(\.expiry).sorted())
    }

    /// The dedicated endpoint's body when it returned a usable payload (2xx, parseable, carrying a
    /// *numeric* `available_count`), otherwise the usage body's embedded object. The count is checked with
    /// `ProviderParse.number` because a JSON `null` decodes to `NSNull`, which a bare nil-check would
    /// accept and then drop the row instead of falling back to the usage-body count.
    private static func resetCreditsSource(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> [String: Any]? {
        if let resetCredits, (200..<300).contains(resetCredits.statusCode),
           let dedicated = ProviderParse.jsonObject(resetCredits.body),
           ProviderParse.number(dedicated["available_count"]) != nil {
            return dedicated
        }
        return body["rate_limit_reset_credits"] as? [String: Any]
    }

    /// The id of the still-available credit whose `expires_at` matches `expiry`, within a second: the
    /// popover's dates come from the same parsing as this list, so a real match is exact and the tolerance
    /// only absorbs sub-second truncation.
    static func resetCreditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        availableResetCredits(in: body).first { credit in
            credit.expiry.map { abs($0.timeIntervalSince(expiry)) < 1 } ?? false
        }?.id
    }

    /// Credits still available to claim. `status` is optional upstream, so a credit with no status counts
    /// as available and only an explicitly non-available state (`redeeming`, `redeemed`) is dropped.
    /// `expires_at` is an ISO-8601 string or an epoch number, and may be null for a credit that never
    /// expires.
    private static func availableResetCredits(in source: [String: Any]) -> [(id: String?, expiry: Date?)] {
        guard let credits = source["credits"] as? [[String: Any]] else { return [] }
        return credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return true }
                return status == "available"
            }
            .map { credit in (credit["id"] as? String, parseExpiry(credit["expires_at"])) }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Collapses a consume response to the popover's outcome. Every protocol code arrives as HTTP 200 with
    /// the outcome in the body's `code`; `already_redeemed` is the idempotency key absorbing a retry of a
    /// claim that already landed, so it counts as success.
    static func resetClaimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        if ProviderError.isAuthFailure(response) { return .failed(.signInExpired) }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let code = body["code"] as? String
        else {
            return .failed(.refused)
        }
        switch code {
        case "reset", "already_redeemed": return .success
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: return .failed(.refused)
        }
    }

    private static func readCreditsRemaining(response: HTTPResponse, body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = ProviderParse.number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return ProviderParse.number(response.header("x-codex-credits-balance"))
    }

    static func formatCodexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro 100"
        case "pro":
            return "Pro 200"
        case "promax":
            return "Pro 500"
        case "self_serve_business_prolite":
            return "Business Premium"
        default:
            return raw.titleCased(separator: { $0 == "_" })
        }
    }

}
