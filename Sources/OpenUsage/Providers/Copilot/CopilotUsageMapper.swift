import Foundation

struct CopilotMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// True for an org-managed (token-based-billing) seat whose response carried no usable per-seat
    /// meters — the signal that the real usage lives in *organization* billing, where the provider
    /// should look next. Kept as an explicit flag so the org lookup is never gated on the incidental
    /// shape of `lines` (see issue #839: a placeholder `overage_permitted` used to sneak an
    /// "Extra Usage: 0" row in and block the lookup).
    var isOrgManagedSeat: Bool = false
}

/// Normalizes the `/copilot_internal/user` response into meters. Since 2026-06-01 every plan is on
/// usage-based billing (AI Credits), so the `premium_interactions` bucket is surfaced as **Credits**
/// (used % of the monthly allotment), with **Extra Usage** carrying overage beyond it (emitted only
/// alongside a real Credits meter — overage is meaningless without an included pool). Paid plans report
/// `chat`/`completions` as the `-1` "unlimited" sentinel (suppressed); free plans carry real `chat` and
/// `completions` counts — either inside `quota_snapshots` (current) or, on older responses, as
/// `limited_user_quotas` against `monthly_quotas`. Zero-entitlement placeholder snapshots — what GitHub
/// returns for Copilot Business token-based-billing seats — carry no real signal and are suppressed
/// rather than rendered as a misleading "0% used" bar.
enum CopilotUsageMapper {
    static let periodMs = MetricPeriod.monthMs

    static func map(_ response: HTTPResponse) throws -> CopilotMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CopilotUsageError.invalidResponse
        }
        return try map(body: body)
    }

    static func map(body: [String: Any]) throws -> CopilotMappedUsage {
        let plan = planLabel(body["copilot_plan"])
        let resetsAt = parseResetDate(body["quota_reset_date"])
            ?? parseResetDate(body["limited_user_reset_date"])

        var lines: [MetricLine] = []

        // The metered premium pool is shown as "Credits"; overage beyond it as "Extra Usage". Extra
        // Usage only exists relative to an included pool, so it's tied to the Credits meter: an
        // org-managed placeholder can carry `overage_permitted: true` on a zero-entitlement bucket,
        // and rendering "0" for it would be meaningless (and used to block the org-billing fallback).
        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"]
        let creditsLine = snapshotLine(label: "Credits", premium, resetsAt: resetsAt)
        appendIfPresent(&lines, creditsLine)
        if creditsLine != nil {
            appendIfPresent(&lines, overageLine(premium))
        }

        // Chat + completions: real per-bucket counts on free; the `-1` "unlimited" sentinel on paid
        // (suppressed by `snapshotLine`). Older free responses without `quota_snapshots` fall back to
        // `limited_user_quotas` / `monthly_quotas` below.
        appendIfPresent(&lines, snapshotLine(label: "Chat", snapshots?["chat"], resetsAt: resetsAt))
        appendIfPresent(&lines, snapshotLine(label: "Completions", snapshots?["completions"], resetsAt: resetsAt))

        // Legacy free-tier shape (predates `quota_snapshots`): remaining counts against monthly limits.
        // Gated on nothing else having been produced — otherwise a paid account (Credits present,
        // chat/completions suppressed as unlimited) that still carried `limited_user_quotas` would
        // wrongly show free-tier meters alongside Credits.
        if lines.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            appendIfPresent(&lines, limitedLine(label: "Chat", remaining: limited?["chat"], total: monthly?["chat"], resetsAt: resetsAt))
            appendIfPresent(&lines, limitedLine(label: "Completions", remaining: limited?["completions"], total: monthly?["completions"], resetsAt: resetsAt))
        }

        // Copilot Business / token-based-billing seats expose no per-seat quota — a legitimate empty
        // state, not a failure. Surface the plan with empty meters (the tiles read "No data") so the
        // dashboard still identifies the plan, instead of a loud error that drops it. A genuinely empty
        // or garbled payload (no token-based-billing marker) is a real problem and fails loudly.
        guard !lines.isEmpty else {
            if ProviderParse.bool(body["token_based_billing"]) == true {
                return CopilotMappedUsage(plan: plan, lines: [], isOrgManagedSeat: true)
            }
            throw CopilotUsageError.quotaUnavailable
        }

        return CopilotMappedUsage(plan: plan, lines: lines)
    }

    // MARK: - Lines

    /// A `quota_snapshots` bucket → percent-used meter, or `nil` to suppress. Suppressed for: a missing
    /// bucket; an `unlimited` bucket or the `-1` entitlement/remaining sentinel (paid chat & completions
    /// under usage-based billing carry no real meter, so they're hidden rather than shown as a misleading
    /// 0%); and a zero-entitlement placeholder (e.g. Credits on a free account, which has no allotment).
    private static func snapshotLine(label: String, _ raw: Any?, resetsAt: Date?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any] else { return nil }

        let entitlement = ProviderParse.number(snapshot["entitlement"])
        let remaining = ProviderParse.number(snapshot["remaining"])

        // Unlimited: the explicit flag, or GitHub's `-1` sentinel on entitlement/remaining. Suppress.
        if ProviderParse.bool(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        // Zero entitlement = no real allotment (token-based-billing placeholder, or Credits on free). Drop it.
        if entitlement == 0 { return nil }

        let usedPercent: Double
        if let percentRemaining = ProviderParse.number(snapshot["percent_remaining"]) {
            usedPercent = ProviderParse.clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = ProviderParse.clampPercent(100 - (remaining / entitlement) * 100)
        } else {
            return nil
        }

        return .progress(
            label: label,
            used: usedPercent,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// "Extra Usage" — premium interactions consumed beyond the included Credits pool. Surfaced only once
    /// the user has enabled additional (overage) spend (`overage_permitted`); a real zero is then shown
    /// ("0"), per the show-real-zeros rule. When overage isn't enabled it's genuinely N/A → `nil`
    /// ("No data"). No spending cap is exposed on this endpoint, so this is an unbounded count, not a meter.
    private static func overageLine(_ raw: Any?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any],
              ProviderParse.bool(snapshot["overage_permitted"]) == true
        else {
            return nil
        }
        let overage = max(0, ProviderParse.number(snapshot["overage_count"]) ?? 0)
        return .values(label: "Extra Usage", values: [MetricValue(number: overage, kind: .count)])
    }

    /// A free-tier bucket: `remaining` against a `total` monthly limit → percent-used meter. `nil` unless
    /// both a positive limit and a remaining count are present (no denominator → no honest percentage).
    private static func limitedLine(label: String, remaining: Any?, total: Any?, resetsAt: Date?) -> MetricLine? {
        guard let total = ProviderParse.number(total), total > 0,
              let remaining = ProviderParse.number(remaining)
        else {
            return nil
        }
        let used = max(0, total - remaining)
        return .progress(
            label: label,
            used: ProviderParse.clampPercent((used / total) * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    private static func appendIfPresent(_ lines: inout [MetricLine], _ line: MetricLine?) {
        if let line { lines.append(line) }
    }

    // MARK: - Field helpers

    private static func planLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.titleCased(separator: { $0 == "_" || $0 == " " || $0 == "-" }, lowercasingTail: true)
    }

    /// Parse a reset timestamp. Paid tier sends an ISO-8601 datetime (`quota_reset_date`, sometimes with
    /// fractional seconds), handled by the shared `OpenUsageISO8601` normalizer; free tier sends a bare
    /// `yyyy-MM-dd` date (`limited_user_reset_date`), the only Copilot-specific fallback kept here.
    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = OpenUsageISO8601.date(from: raw) { return date }
        return dayOnlyFormatter.date(from: raw)
    }

    /// `nonisolated(unsafe)` is sound: `DateFormatter` is documented thread-safe on macOS 10.9+, and the
    /// formatter is never mutated after creation (same pattern as `CursorUsageCSV`/`OpenUsageISO8601`).
    private nonisolated(unsafe) static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum CopilotUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case connectionFailed
    case requestFailed(Int)
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Copilot usage response invalid. Try again later."
        case .connectionFailed:
            return "Couldn't reach GitHub. Check your connection."
        case .requestFailed(let status):
            return "Copilot usage request failed (HTTP \(status)). Try again later."
        case .quotaUnavailable:
            return "Copilot usage data is unavailable for this account."
        }
    }
}
