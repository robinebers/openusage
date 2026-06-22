import Foundation

struct CodexMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CodexUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs
    /// Codex flex credits are worth 4¢ each; the credits line leads with the dollar value
    /// (mirrors the JS plugin's `CREDIT_USD_RATE`).
    static let creditUSDRate = 0.04

    static func mapUsageResponse(
        _ response: HTTPResponse,
        resetCredits: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> CodexMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: CodexAuthError.tokenExpired,
            requestFailed: { CodexUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CodexUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        let primaryWindow = rateLimit?["primary_window"] as? [String: Any]
        let secondaryWindow = rateLimit?["secondary_window"] as? [String: Any]

        if let headerPrimary = ProviderParse.number(response.header("x-codex-primary-used-percent")) {
            lines.append(progress(
                label: "Session",
                used: headerPrimary,
                resetWindow: primaryWindow,
                now: now,
                periodDurationMs: sessionPeriodMs
            ))
        }
        if let headerSecondary = ProviderParse.number(response.header("x-codex-secondary-used-percent")) {
            lines.append(progress(
                label: "Weekly",
                used: headerSecondary,
                resetWindow: secondaryWindow,
                now: now,
                periodDurationMs: weeklyPeriodMs
            ))
        }

        if !lines.contains(where: { $0.label == "Session" }),
           let used = ProviderParse.number(primaryWindow?["used_percent"]) {
            lines.append(progress(
                label: "Session",
                used: used,
                resetWindow: primaryWindow,
                now: now,
                periodDurationMs: sessionPeriodMs
            ))
        }
        if !lines.contains(where: { $0.label == "Weekly" }),
           let used = ProviderParse.number(secondaryWindow?["used_percent"]) {
            lines.append(progress(
                label: "Weekly",
                used: used,
                resetWindow: secondaryWindow,
                now: now,
                periodDurationMs: weeklyPeriodMs
            ))
        }

        appendAdditionalRateLimits(from: body, to: &lines, now: now)
        appendReviewLimit(from: body, to: &lines, now: now)

        // On-demand rate-limit reset credits, shown before Credits — mirrors the JS plugin (PR #577).
        // The row reads "2 available" (the count is carried raw, so the menu-bar tile reads the same
        // number); each still-available credit's expiry rides along in `expiriesAt` and surfaces in the
        // row's hover tooltip ("Resets expire in: …").
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

        // The "no usage data" badge is appended by `CodexProvider.probe` *after* the ccusage spend
        // lines, so an empty live response never yields a badge that coexists with Today/Yesterday.
        return CodexMappedUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
    }

    private static func appendAdditionalRateLimits(from body: [String: Any], to lines: inout [MetricLine], now: Date) {
        guard let entries = body["additional_rate_limits"] as? [[String: Any]] else { return }
        for entry in entries {
            guard let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
            let rawName = (entry["limit_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shortName = rawName.replacingOccurrences(
                of: #"^GPT-[\d.]+-Codex-"#,
                with: "",
                options: .regularExpression
            )
            let label = shortName.isEmpty ? (rawName.isEmpty ? "Model" : rawName) : shortName

            if let primary = rateLimit["primary_window"] as? [String: Any],
               let used = ProviderParse.number(primary["used_percent"]) {
                lines.append(progress(
                    label: label,
                    used: used,
                    resetWindow: primary,
                    now: now,
                    periodDurationMs: readPeriodMs(primary) ?? sessionPeriodMs
                ))
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any],
               let used = ProviderParse.number(secondary["used_percent"]) {
                lines.append(progress(
                    label: "\(label) Weekly",
                    used: used,
                    resetWindow: secondary,
                    now: now,
                    periodDurationMs: readPeriodMs(secondary) ?? weeklyPeriodMs
                ))
            }
        }
    }

    private static func appendReviewLimit(from body: [String: Any], to lines: inout [MetricLine], now: Date) {
        guard let review = body["code_review_rate_limit"] as? [String: Any],
              let window = review["primary_window"] as? [String: Any],
              let used = ProviderParse.number(window["used_percent"])
        else {
            return
        }
        lines.append(progress(
            label: "Reviews",
            used: used,
            resetWindow: window,
            now: now,
            periodDurationMs: weeklyPeriodMs
        ))
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

    private static func readPeriodMs(_ window: [String: Any]) -> Int? {
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]) else { return nil }
        return Int(seconds * 1000)
    }

    /// Codex flex credits as raw values: the floored credit count and its dollar value (count × 4¢),
    /// shown combined as e.g. "$32.84 · 821 credits". The count is floored *before* pricing to match the
    /// Codex CLI/plugin (so OpenUsage's dollar agrees with Codex's own), which keeps the two values
    /// mutually consistent. Negative balances clamp to zero, so an exhausted balance reads
    /// "$0.00 · 0 credits" — a real, measured zero, not "No data".
    static func creditValues(remaining: Double) -> [MetricValue] {
        let credits = max(0, Int(remaining.rounded(.down)))
        let usd = Double(credits) * creditUSDRate
        return [
            MetricValue(number: usd, kind: .dollars),
            MetricValue(number: Double(credits), kind: .count, label: "credits")
        ]
    }

    /// On-demand reset credits: the floored available count plus each still-available credit's expiry
    /// (sorted soonest-first, for the row's hover tooltip).
    ///
    /// Prefers the dedicated `/rate-limit-reset-credits` payload (the only source that carries the
    /// per-credit expiry list); falls back to the usage body's embedded `rate_limit_reset_credits`
    /// object (count only) when that fetch was unavailable — mirroring the JS plugin. `ProviderParse.number`
    /// returns nil for missing/null/non-numeric counts, so a malformed count skips the row entirely.
    static func readResetCredits(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> (count: Int, expiries: [Date])? {
        guard let source = resetCreditsSource(body: body, resetCredits: resetCredits),
              let count = ProviderParse.number(source["available_count"]), count >= 0
        else {
            return nil
        }
        return (Int(count.rounded(.down)), availableExpiries(in: source["credits"]))
    }

    /// The dictionary the count and expiry list are read from: the dedicated endpoint's body when it
    /// returned a usable payload (2xx, parseable, carrying a *numeric* `available_count`), otherwise the
    /// usage body's embedded object. The count is validated with `ProviderParse.number` rather than a bare
    /// nil-check: a JSON `null` decodes to `NSNull` (non-nil), so a bare check would select a dedicated
    /// body whose count is unusable and drop the row instead of falling back to the usage-body count.
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

    /// Every still-available credit's `expires_at`, sorted soonest-first. `status` is optional upstream,
    /// so a credit is kept when it's explicitly "available" *or* carries no status at all — only an
    /// explicitly non-available state (e.g. "consumed"/"expired") is dropped. Filtering hard on
    /// `== "available"` would otherwise blank the whole expiry list (tooltip + 24h warning) for responses
    /// that omit status, even though `available_count` reported credits. `expires_at` is parsed as an
    /// ISO-8601 string or an epoch number.
    private static func availableExpiries(in value: Any?) -> [Date] {
        guard let credits = value as? [[String: Any]] else { return [] }
        return credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return true }
                return status == "available"
            }
            .compactMap { parseExpiry($0["expires_at"]) }
            .sorted()
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
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return raw.titleCased(separator: { $0 == "_" })
        }
    }

}

enum CodexUsageError: Error, LocalizedError, Equatable {
    case requestFailed(Int)
    case invalidResponse
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        }
    }
}

