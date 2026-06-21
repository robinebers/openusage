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

    static func mapUsageResponse(_ response: HTTPResponse, now: Date = Date()) throws -> CodexMappedUsage {
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
        // A `.values` row carries the raw count (no unit label — the row just reads "2"), so the popover
        // and the menu-bar tile show that same number — no string to re-parse, no tray-reads-0 bug.
        if let resets = readResetCredits(body), resets >= 0 {
            let count = Int(resets.rounded(.down))
            lines.append(.values(label: "Rate Limit Resets",
                                 values: [MetricValue(number: Double(count), kind: .count)]))
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

    /// On-demand reset credits from `rate_limit_reset_credits.available_count`. `ProviderParse.number`
    /// returns nil for missing/null/non-numeric values, so malformed counts are skipped (matches JS).
    private static func readResetCredits(_ body: [String: Any]) -> Double? {
        guard let resets = body["rate_limit_reset_credits"] as? [String: Any] else { return nil }
        return ProviderParse.number(resets["available_count"])
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

