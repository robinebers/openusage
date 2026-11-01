import Foundation

enum ClaudeUsageMapper {
    static func mapUsageResponse(_ response: HTTPResponse) throws -> [MetricLine] {
        try ProviderError.requireSuccess(response, kind: .claude)

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }

        var lines: [MetricLine] = []
        appendUsageWindow(body["five_hour"], label: "Session", periodDurationMs: MetricPeriod.sessionMs, to: &lines)
        appendUsageWindow(body["seven_day"], label: "Weekly", periodDurationMs: MetricPeriod.weekMs, to: &lines)
        appendUsageWindow(body["seven_day_sonnet"], label: "Sonnet", periodDurationMs: MetricPeriod.weekMs, to: &lines)
        appendScopedWeeklyLimit(body["limits"], modelName: "Fable", label: "Fable", to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)
        return lines
    }

    static func mapResetGrantStatus(_ response: HTTPResponse) throws -> ClaudeResetGrantStatus? {
        try ProviderError.requireSuccess(response, kind: .claude)
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }
        return ClaudeResetGrantStatus.parse(body["cedar_ember"])
    }

    static func resetClaimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        // Anthropic answers a token whose scopes don't cover an endpoint with a 403 whose message reads
        // "OAuth token does not meet scope requirement …"; that is the sign-in's grant, not an expiry.
        if response.statusCode == 403, String(decoding: response.body, as: UTF8.self).contains("scope requirement") {
            return .failed(.notPermitted)
        }
        if ProviderError.isAuthFailure(response) { return .failed(.signInExpired) }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let result = body["result"] as? String
        else { return .failed(.refused) }
        let cooldownUntil = resetDate(body["cooldown_until"])
        func outcome(_ code: String) -> ResetClaimOutcome? {
            switch code {
            case "reset", "already_used": .success
            case "not_limited": .nothingToReset
            case "ineligible", "no_grant", "unknown_grant", "not_next_grant": .noCredit
            case "reset_unconfirmed", "stamp_indeterminate": .unconfirmed
            case "cooldown", "paused", "low_priority_active": .unavailableNow(until: cooldownUntil)
            default: nil
            }
        }
        if result == "unavailable" {
            return (body["reason"] as? String).flatMap(outcome) ?? .failed(.refused)
        }
        return outcome(result) ?? .failed(.refused)
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)
        let tier = rateLimitTier ?? ""
        if base == "Ultra" || (base == "Max" && (tier.contains("ultra") || tier.contains("20x"))) { return "Ultra" }
        if base == "Max" { return base }

        guard let match = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[match])"
    }

    static func formatLivePlan(profile: ClaudeAccountProfile) -> String? {
        guard let organization = profile.organization else { return nil }
        let subscriptionType = organization.organizationType.map { type in
            type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        }
        return formatPlan(subscriptionType: subscriptionType, rateLimitTier: organization.rateLimitTier)
    }

    private static func appendUsageWindow(_ value: Any?, label: String, periodDurationMs: Int, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              let used = ProviderParse.number(object["utilization"])
        else {
            return
        }
        lines.append(.percent(label, used, resetsAt: resetDate(object["resets_at"]), periodMs: periodDurationMs))
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
            lines.append(.percent(label, used, resetsAt: resetDate(object["resets_at"]), periodMs: MetricPeriod.weekMs))
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
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    static func resetDate(_ value: Any?) -> Date? {
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

}
