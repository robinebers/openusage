import Foundation

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload and the plan name from
/// `/api/biz/subscription/list`. Ports and extends the legacy Tauri plugin's mapping:
/// - a `TOKENS_LIMIT` entry whose window is sub-daily (`unit: 3`, hours) is the 5-hour session meter,
/// - a `TOKENS_LIMIT` entry whose window is multi-day (`unit: 6`, weeks) is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search/reader count meter (used / limit).
///
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI; the response
/// shapes are stable in practice. The mapper is pure (no I/O) so it tests cleanly against sample
/// payloads, exactly like the legacy plugin's fixture-based tests.
enum ZAIUsageMapper {
    /// One monthly web-search cycle, in milliseconds (Z.ai reports `unit: 5, number: 1`). The session
    /// and weekly meters instead carry the *payload's* actual window (see `classifyTokenWindow`), so
    /// their cadence tracks the plan rather than a hardcoded assumption; this monthly constant is only a
    /// fallback for the web-search line and the widget-descriptor default.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    /// `(plan, lines)` from the quota + subscription payloads. `subscription` may be `nil` (the
    /// request is best-effort) and the quota's `limits` array may carry one to three entries — only
    /// what's present is mapped, so a plan without web searches still shows the session meter.
    static func map(quotaBody: Data, subscriptionBody: Data?) -> (plan: String?, lines: [MetricLine]) {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        let lines = mapQuota(quotaBody)
        return (plan, lines)
    }

    /// True when a 2xx quota body is the "valid key, but no GLM Coding Plan" signal: Z.ai answers
    /// `{"success":false,"code":500,"msg":"…coding plan"}` with no `data`. The provider turns this into a
    /// clear `.notAvailable` error (a header warning) instead of three blank "No data" meters that don't
    /// say why. Matched on the structured `success:false` plus the "coding plan" phrase the message
    /// carries (ASCII even in the localized string), so an unrelated business failure doesn't trip it.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// Session + weekly + web-search meters from the quota payload. Emits the "No usage data"
    /// placeholder when the payload carries no usable limits, matching the legacy plugin.
    static func mapQuota(_ body: Data) -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else { return [.noUsageData] }
        // The limits array lives under `data.limits`; the legacy plugin also tolerated the root object
        // being the container directly (no `data` wrapper), so honor both.
        let container = root["data"] as? [String: Any] ?? root
        guard let limits = container["limits"] as? [[String: Any]], !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []

        // Split the TOKENS_LIMIT entries by window length: a sub-daily window is the session meter,
        // a multi-day window is the weekly meter. Z.ai reports both, and both are percentage meters.
        let tokenLimits = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" || ($0["name"] as? String) == "TOKENS_LIMIT" }
        for entry in tokenLimits {
            switch classifyTokenWindow(entry) {
            case .session(let periodMs):
                lines.append(percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(percentLine(entry, label: "Weekly", periodMs: periodMs))
            case .unknown:
                continue
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            lines.append(webSearchLine(from: web))
        }

        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    /// `productName` from the first valid subscription entry (e.g. "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// How a `TOKENS_LIMIT` entry's window maps to a meter. Z.ai encodes the window as a `(unit, number)`
    /// pair: `unit: 3` is hours (session), `unit: 6` is weeks (weekly), `unit: 5` is months. A sub-daily
    /// window is the session meter; a multi-day window is the weekly meter; anything unrecognized is
    /// skipped so a future unit value can't silently overwrite a known meter.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
        case unknown
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) -> TokenWindow {
        guard let periodMs = periodDurationMs(for: entry) else { return .unknown }
        // Sub-daily → session; multi-day → weekly. The computed window rides along so the meter's
        // cadence reflects the payload instead of a hardcoded constant.
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    /// Resolve a `(unit, number)` window to milliseconds. `unit` is Z.ai's internal time-unit code.
    private static func periodDurationMs(for entry: [String: Any]) -> Int? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]) else {
            return nil
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000           // hours
        case 4: unitMs = 24 * 60 * 60 * 1000      // days
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000  // weeks
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000 // months
        default: return nil
        }
        return Int(unitMs * number)
    }

    /// A percentage meter (Session or Weekly) from a `TOKENS_LIMIT` entry.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) -> MetricLine {
        let percentage = ProviderParse.clampPercent(ProviderParse.number(entry["percentage"]) ?? 0)
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    private static func webSearchLine(from entry: [String: Any]) -> MetricLine {
        let used = max(0, ProviderParse.number(entry["currentValue"]) ?? 0)
        let limit = max(0, ProviderParse.number(entry["usage"]) ?? 0)
        // TIME_LIMIT carries a nextResetTime in current payloads (monthly renewal); honor it when
        // present so the countdown shows the real reset, otherwise the period cadence reads "monthly".
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: monthlyPeriodMs
        )
    }

    /// A limit entry matches by `type` or `name`; the legacy plugin checked both because Z.ai's
    /// payload has used either field across revisions.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    /// `nextResetTime` arrives as epoch milliseconds (e.g. `1770648402389`).
    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
