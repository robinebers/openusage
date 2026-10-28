import Foundation

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload and the plan name from
/// `/api/biz/subscription/list`:
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is sub-daily (`unit: 3`, hours)
///   is the 5-hour session meter,
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is multi-day (`unit: 6`, weeks)
///   is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search/reader count meter (used / limit).
///
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI; the response
/// shapes are stable in practice. The mapper is pure (no I/O) so it tests cleanly against sample
/// payloads.
enum ZAIUsageMapper {
    /// The plan and lines from the quota + subscription payloads. `subscription` may be `nil` (the
    /// request is best-effort) and the quota's `limits` array may carry one to three entries — only
    /// what's present is mapped, so a plan without web searches still shows the session meter.
    static func map(quotaBody: Data, subscriptionBody: Data?) throws -> ProviderUsage {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        return ProviderUsage(plan: plan, lines: try mapQuota(quotaBody))
    }

    /// Session + weekly + web-search meters from the quota payload. Missing required values are an
    /// invalid response rather than zero usage; an explicit empty array remains a valid no-data state.
    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ProviderError.invalidResponse
        }
        // The limits array lives under `data.limits`, or at the root when there is no `data` wrapper.
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ProviderError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        guard !limits.isEmpty else {
            return []
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        // Split the percentage quota entries by window length: a sub-daily window is the session
        // meter, and a multi-day window is the weekly meter. Current responses call these
        // CREDIT_LIMIT; older plans used TOKENS_LIMIT for the same shape.
        let percentageLimits = limits.filter {
            let type = ($0["type"] as? String) ?? ($0["name"] as? String)
            return type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT"
        }
        for entry in percentageLimits {
            guard let window = try classifyTokenWindow(entry) else { continue }
            sawRecognizedLimit = true
            switch window {
            case .session(let periodMs):
                lines.append(try percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(try percentLine(entry, label: "Weekly", periodMs: periodMs))
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            sawRecognizedLimit = true
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ProviderError.invalidResponse }
            return []
        }
        return lines
    }

    /// `productName` from the first valid subscription entry, Z.ai's own plan name (e.g. "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// How a percentage quota entry's window maps to a meter. Z.ai encodes the window as a
    /// `(unit, number)` pair: `unit: 3` is hours (session), `unit: 6` is weeks (weekly), `unit: 5` is
    /// months. A sub-daily window is the session meter; a multi-day window is the weekly meter.
    /// Unknown units are ignored so a future Z.ai window cannot hide meters whose units OpenUsage
    /// still understands.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            throw ProviderError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            throw ProviderError.invalidResponse
        }
        let periodMs = Int(duration)
        // Sub-daily → session; multi-day → weekly. The computed window rides along so the meter's
        // cadence reflects the payload instead of a hardcoded constant.
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    /// A percentage meter (Session or Weekly) from a credit/token quota entry.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            throw ProviderError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .percent(label, percentage, resetsAt: resetsAt, periodMs: periodMs)
    }

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            throw ProviderError.invalidResponse
        }
        // TIME_LIMIT carries a nextResetTime in current payloads (monthly renewal); honor it when
        // present so the countdown shows the real reset, otherwise the period cadence reads "monthly".
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: MetricPeriod.monthMs
        )
    }

    /// A limit entry matches by `type` or `name`: Z.ai's payload has used either field across revisions.
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
