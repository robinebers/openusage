import Foundation

/// Builds metric lines from the ollama.com `/api/usage` payload and the plan name from `/api/me`.
///
/// The usage payload looks like:
///
///     {"activity": {"cost": "0.00000", "period": {"type": "last_4_weeks", …}, "models": []},
///      "limits": {"session": {"usage": 0.349, "models": […]},
///                 "weekly":  {"usage": 0.316, "models": […]},
///                 "monthly": {"usage": 0.053, "models": […]}}}
///
/// `usage` is a **fraction** of the plan's allowance (0.349 → 34.9%), not a percentage.
///
/// The limits carry no reset instant. Ollama documents the window *lengths* (session every 5 hours,
/// weekly every 7 days) but not when the current window started, so the meters deliberately carry no
/// `resetsAt` and no `periodDurationMs`: a period with no reset date renders as a flat "Resets in 5h"
/// that never counts down, which reads as a real countdown while being pure guesswork. The window
/// lengths live in `docs/providers/ollama.md` instead, where they can be stated as cadence.
///
/// The endpoint is undocumented (it backs Ollama's own settings page), so every field is read
/// defensively: a limit that isn't present is simply not metered, rather than shown as zero usage.
/// The mapper is pure — no I/O — so it tests directly against sample payloads.
enum OllamaUsageMapper {
    /// `(plan, lines)` from the usage payload plus the optional account payload. `accountBody` may be
    /// `nil` — the plan request is best-effort and must never blank out the meters.
    static func map(usageBody: Data, accountBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = accountBody.flatMap { planName(from: $0) }
        return (plan, try usageLines(usageBody))
    }

    /// Session, weekly, and monthly meters plus the recent-activity spend row.
    static func usageLines(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw OllamaUsageError.invalidResponse
        }
        // `limits` is the reason this endpoint exists; its absence means the response isn't the shape
        // OpenUsage understands, which is a loud failure rather than an empty dashboard.
        guard let limits = root["limits"] as? [String: Any] else {
            throw OllamaUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let session = percentLine(limits["session"], label: "Session") {
            lines.append(session)
        }
        if let weekly = percentLine(limits["weekly"], label: "Weekly") {
            lines.append(weekly)
        }
        if let monthly = percentLine(limits["monthly"], label: "Monthly") {
            lines.append(monthly)
        }
        if let activity = activityLine(root["activity"]) {
            lines.append(activity)
        }
        return lines.isEmpty ? [.noUsageData] : lines
    }

    /// The account's plan, title-cased for the header badge ("pro" → "Pro"). Called directly, ollama.com
    /// capitalizes its JSON keys (`Plan`); the local Ollama server lowercases them when it proxies the
    /// same response, so both spellings are accepted.
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body) else { return nil }
        let raw = (root["Plan"] as? String) ?? (root["plan"] as? String)
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        return name.capitalized
    }

    // MARK: - Private

    /// One limit entry → a 0–100% meter. `usage` is a fraction of the plan allowance, so it scales by 100.
    /// A missing entry or a missing `usage` yields no line: the meter is absent, not at zero.
    private static func percentLine(_ entry: Any?, label: String) -> MetricLine? {
        guard let entry = entry as? [String: Any],
              let fraction = ProviderParse.number(entry["usage"]) else { return nil }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(fraction * 100),
            limit: 100,
            format: .percent
        )
    }

    /// `activity.cost` → an unbounded dollar row. Ollama reports it as a decimal string ("0.00000") over
    /// a rolling four-week window; it stays $0.00 on a subscription and carries real spend for
    /// pay-as-you-go and API-key usage. The label is fixed so it always matches its widget descriptor —
    /// `activity.period` is informational and is not used to rename the row.
    private static func activityLine(_ activity: Any?) -> MetricLine? {
        guard let activity = activity as? [String: Any],
              let cost = ProviderParse.number(activity["cost"]),
              cost >= 0 else { return nil }
        return .values(
            label: "Last 4 Weeks",
            values: [MetricValue(number: cost, kind: .dollars)]
        )
    }
}
