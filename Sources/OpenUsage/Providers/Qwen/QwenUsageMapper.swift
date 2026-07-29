import Foundation

/// Maps home.qwencloud.com token-plan payloads into metric lines. All three gateway endpoints share
/// one envelope — the actual payload sits at `.data.DataV2.data.data` — and report percentages as
/// fractions of 1.0 with reset times in epoch milliseconds. Pure (no I/O), so it tests against
/// captured payloads.
enum QwenUsageMapper {
    /// A parsed subscription endpoint: the tier key exactly as the API spells it (`specCode`, used
    /// to look up quota caps), the display name, and — only when auto-renew is off — the warning the
    /// provider surfaces in the card header.
    struct SubscriptionInfo: Equatable {
        var tierKey: String
        var planName: String
        var renewalWarning: String?
    }

    /// Absolute quota caps for one tier, from `quota-config`. The dashboard's own units for these
    /// numbers aren't published, so they surface in the plan label as bare numbers rather than a
    /// claimed unit.
    struct QuotaCaps: Equatable {
        var fiveHour: Double
        var weekly: Double
    }

    /// `data.secToken` from an `info.json` body — the CSRF token every gateway call needs, and the
    /// session-liveness signal: a dead session answers without one.
    static func secToken(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let data = root["data"] as? [String: Any] else { return nil }
        return (data["secToken"] as? String)?.nilIfEmpty
    }

    /// True when a 2xx body is the gateway's "not logged in" answer (`ConsoleNeedLogin`, or
    /// `successResponse: false` without a payload) rather than a genuine success or an unrelated
    /// business error — the provider maps it to `.sessionExpired` instead of a generic failure.
    static func isConsoleLoginFailure(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body) else { return false }
        if let code = (root["code"] as? String), code == "ConsoleNeedLogin" { return true }
        if ((root["data"] as? [String: Any])?["errorCode"] as? String) == "ConsoleNeedLogin" { return true }
        if (root["successResponse"] as? Bool) == false { return true }
        return false
    }

    /// Session (5-hour) + weekly meters from a `usage` payload. A missing percentage is an invalid
    /// response rather than zero usage; reset times are optional (a missing one just drops the
    /// countdown).
    static func mapUsage(_ body: Data) throws -> [MetricLine] {
        let payload = try innerData(body)
        return [
            try percentLine(payload,
                            percentKey: "per5HourPercentage",
                            resetKey: "per5HourResetTime",
                            label: "5-Hour",
                            periodMs: MetricPeriod.sessionMs),
            try percentLine(payload,
                            percentKey: "per1WeekPercentage",
                            resetKey: "per1WeekResetTime",
                            label: "Weekly",
                            periodMs: MetricPeriod.weekMs)
        ]
    }

    /// Tier + renewal state from a `subscription` payload.
    static func mapSubscription(_ body: Data) throws -> SubscriptionInfo {
        let payload = try innerData(body)
        guard let tierKey = (payload["specCode"] as? String)?.nilIfEmpty else {
            throw QwenUsageError.invalidResponse
        }
        let planName = tierKey.titleCased(separator: { $0 == "_" || $0 == "-" || $0 == " " })
        var warning: String?
        if ProviderParse.bool(payload["autoRenewFlag"]) == false {
            if let days = ProviderParse.number(payload["remainingDays"]), days >= 0 {
                let whole = Int(days)
                warning = "Auto-renew is off — plan ends in \(whole) \(whole == 1 ? "day" : "days")."
            } else {
                warning = "Auto-renew is off for this plan."
            }
        }
        return SubscriptionInfo(tierKey: tierKey, planName: planName, renewalWarning: warning)
    }

    /// The caps entry for one tier key from a `quota-config` payload (`standard`, `lite`, `pro`…),
    /// or nil when the tier or its numbers are absent — best-effort decoration, never an error.
    static func quotaCaps(_ body: Data, tierKey: String) -> QuotaCaps? {
        guard let payload = try? innerData(body),
              let entry = payload[tierKey] as? [String: Any],
              let fiveHour = ProviderParse.number(entry["five_hour"]),
              let weekly = ProviderParse.number(entry["weekly"]),
              fiveHour >= 0, weekly >= 0 else { return nil }
        return QuotaCaps(fiveHour: fiveHour, weekly: weekly)
    }

    /// The header plan label: "Standard" alone, or "Standard · 3,000 / 5h · 10,000 / wk" when the
    /// quota-config lookup found caps for the tier.
    static func planLabel(planName: String, caps: QuotaCaps?) -> String {
        guard let caps else { return planName }
        return "\(planName) · \(formatCap(caps.fiveHour)) / 5h · \(formatCap(caps.weekly)) / wk"
    }

    // MARK: - Private

    /// Unwrap `.data.DataV2.data.data` and verify the success markers. Login failures keep an HTTP
    /// 200 envelope, so they are detected on the way through and surfaced as `.sessionExpired`.
    private static func innerData(_ body: Data) throws -> [String: Any] {
        guard let root = ProviderParse.jsonObject(body),
              let data = root["data"] as? [String: Any] else {
            throw QwenUsageError.invalidResponse
        }
        if (data["errorCode"] as? String) == "ConsoleNeedLogin" {
            throw QwenUsageError.sessionExpired
        }
        guard let dataV2 = data["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any] else {
            throw QwenUsageError.invalidResponse
        }
        if let code = (inner["code"] as? String), code != "SUCCESS" {
            throw code == "ConsoleNeedLogin" ? QwenUsageError.sessionExpired : QwenUsageError.invalidResponse
        }
        guard let payload = inner["data"] as? [String: Any] else {
            throw QwenUsageError.invalidResponse
        }
        return payload
    }

    /// One percentage meter. Percentages arrive as fractions of 1.0 (e.g. `0.315` = 31.5%); a
    /// negative value is malformed, an over-100 result is clamped at the display edge.
    private static func percentLine(
        _ payload: [String: Any],
        percentKey: String,
        resetKey: String,
        label: String,
        periodMs: Int
    ) throws -> MetricLine {
        guard let fraction = ProviderParse.number(payload[percentKey]), fraction >= 0 else {
            throw QwenUsageError.invalidResponse
        }
        let resetsAt = ProviderParse.number(payload[resetKey]).map { epochMsToDate($0) }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(fraction * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// `12000.0` → "12,000"; whole numbers drop the decimal, nothing else is asserted about units.
    private static func formatCap(_ value: Double) -> String {
        if value.rounded() == value {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            if let text = formatter.string(from: NSNumber(value: value)) { return text }
        }
        return String(value)
    }

    /// Reset times arrive as epoch milliseconds (e.g. `1785353040000`).
    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
