import Foundation

struct CopilotMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes the `/copilot_internal/user` response into progress meters. The endpoint reports each
/// bucket as percent *remaining*; every meter flips that to percent *used*. Two response shapes are
/// handled: paid plans expose `quota_snapshots` (Premium / Chat / Completions), free plans expose
/// `limited_user_quotas` against `monthly_quotas` (Chat / Completions). Zero-entitlement placeholder
/// snapshots — what GitHub returns for Copilot Business token-based-billing seats — carry no real quota
/// signal and are suppressed rather than rendered as a misleading "0% used" bar.
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

        // Paid tier: per-bucket quota snapshots.
        let snapshots = body["quota_snapshots"] as? [String: Any]
        appendIfPresent(&lines, snapshotLine(label: "Premium", snapshots?["premium_interactions"], resetsAt: resetsAt))
        appendIfPresent(&lines, snapshotLine(label: "Chat", snapshots?["chat"], resetsAt: resetsAt))
        appendIfPresent(&lines, snapshotLine(label: "Completions", snapshots?["completions"], resetsAt: resetsAt))

        // Free tier: remaining counts (`limited_user_quotas`) against monthly limits (`monthly_quotas`).
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
            if readBool(body["token_based_billing"]) == true {
                return CopilotMappedUsage(plan: plan, lines: [])
            }
            throw CopilotUsageError.quotaUnavailable
        }

        return CopilotMappedUsage(plan: plan, lines: lines)
    }

    // MARK: - Lines

    /// A paid-tier `quota_snapshots` bucket → percent-used meter. `nil` for a missing bucket, an
    /// `unlimited` bucket rendered as an empty (0% used) meter with no reset, or a zero-entitlement
    /// placeholder seat (suppressed).
    private static func snapshotLine(label: String, _ raw: Any?, resetsAt: Date?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any] else { return nil }

        if readBool(snapshot["unlimited"]) == true {
            return .progress(label: label, used: 0, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)
        }

        let entitlement = ProviderParse.number(snapshot["entitlement"])
        let remaining = ProviderParse.number(snapshot["remaining"])

        // Zero entitlement = no real allotment (token-based-billing placeholder). Drop it.
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
    /// fractional seconds); free tier sends a bare `yyyy-MM-dd` date (`limited_user_reset_date`).
    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: raw) { return date }

        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: raw)
    }

    private static func readBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
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
