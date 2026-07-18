import Foundation

/// Builds metric lines from the Kimi Code `GET /coding/v1/usages` payload. Ports the legacy Tauri
/// plugin's mapping to the shape the API returns today:
/// - `limits[]` entries carry a `window` (`duration` + `timeUnit`) and a `detail` quota — the
///   shortest window is the Session meter (300 minutes = the 5-hour window in current payloads),
/// - the top-level `usage` quota is the long (weekly) allowance,
/// - `user.membership.level` ("LEVEL_INTERMEDIATE") becomes the plan label ("Intermediate").
///
/// Quota numbers arrive as strings ("100"); `ProviderParse.number` reads both shapes. The endpoint is
/// the one the Kimi Code CLI's own usage view calls; the mapper is pure (no I/O) so it tests cleanly
/// against sample payloads.
enum KimiUsageMapper {
    /// `(plan, lines)` from the usage payload. A payload without the known quota containers is an
    /// invalid response; recognized containers that hold no usable quota map to the no-data badge.
    static func map(_ body: Data) throws -> (plan: String?, lines: [MetricLine]) {
        guard let root = ProviderParse.jsonObject(body) else {
            throw KimiUsageError.invalidResponse
        }
        let windowed = try windowedCandidates(root)
        let usage = try usageCandidate(root)
        guard root["limits"] != nil || root["usage"] != nil else {
            throw KimiUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        // The shortest declared window is the session meter; entries without a readable window sort last.
        let session = windowed.min { ($0.periodMs ?? Int.max) < ($1.periodMs ?? Int.max) }
        if let session {
            lines.append(progressLine(label: "Session", candidate: session))
        }
        // The weekly meter prefers the top-level `usage` quota; if that ever disappears, the longest
        // remaining known window stands in. A weekly quota identical to the session one (a plan with a
        // single window) is not repeated.
        let weekly = usage ?? windowed.filter { $0 != session }.max { ($0.periodMs ?? -1) < ($1.periodMs ?? -1) }
        if let weekly, weekly.quota != session?.quota {
            lines.append(progressLine(label: "Weekly", candidate: weekly))
        }

        guard !lines.isEmpty else {
            return (plan(root), [.noUsageData])
        }
        return (plan(root), lines)
    }

    // MARK: - Private

    struct Candidate: Hashable {
        var quota: Quota
        var periodMs: Int?
    }

    struct Quota: Hashable {
        var used: Double
        var limit: Double
        var resetsAt: Date?
    }

    /// One candidate per `limits[]` entry: the quota from `detail` (or the entry itself in older
    /// payloads) plus the window length. An entry that carries a positive `limit` but no readable
    /// used/remaining pair is an invalid response rather than zero usage; entries without a limit
    /// (an unknown future shape) are skipped so they can't hide the meters that do parse.
    private static func windowedCandidates(_ root: [String: Any]) throws -> [Candidate] {
        guard let limits = root["limits"] as? [[String: Any]] else { return [] }
        var candidates: [Candidate] = []
        for entry in limits {
            let detail = (entry["detail"] as? [String: Any]) ?? entry
            guard let quota = try quota(from: detail) else { continue }
            candidates.append(Candidate(quota: quota, periodMs: windowPeriodMs(entry["window"])))
        }
        return candidates
    }

    private static func usageCandidate(_ root: [String: Any]) throws -> Candidate? {
        guard let usage = root["usage"] as? [String: Any],
              let quota = try quota(from: usage)
        else {
            return nil
        }
        return Candidate(quota: quota, periodMs: nil)
    }

    /// `nil` when the entry carries no positive `limit` (not a quota); throws when a quota's usage is
    /// unreadable — missing required values are an invalid response, not zero usage.
    private static func quota(from object: [String: Any]) throws -> Quota? {
        guard let limit = ProviderParse.number(object["limit"]), limit > 0 else { return nil }
        var used = ProviderParse.number(object["used"])
        if used == nil, let remaining = ProviderParse.number(object["remaining"]) {
            used = limit - remaining
        }
        guard let used else { throw KimiUsageError.invalidResponse }
        let resetsAt = (object["resetTime"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return Quota(used: used, limit: limit, resetsAt: resetsAt)
    }

    /// `window.duration` + `window.timeUnit` ("TIME_UNIT_MINUTE") → milliseconds. Unknown units are
    /// `nil` so a future window shape degrades to "no cadence" instead of a wrong one.
    private static func windowPeriodMs(_ value: Any?) -> Int? {
        guard let window = value as? [String: Any],
              let duration = ProviderParse.number(window["duration"]), duration > 0,
              let unit = window["timeUnit"] as? String
        else {
            return nil
        }
        let unitMs: Double
        switch unit.uppercased() {
        case let u where u.contains("SECOND"): unitMs = 1000
        case let u where u.contains("MINUTE"): unitMs = 60 * 1000
        case let u where u.contains("HOUR"): unitMs = 60 * 60 * 1000
        case let u where u.contains("DAY"): unitMs = 24 * 60 * 60 * 1000
        default: return nil
        }
        let periodMs = duration * unitMs
        guard periodMs >= 1, periodMs < Double(Int.max) else { return nil }
        return Int(periodMs)
    }

    private static func progressLine(label: String, candidate: Candidate) -> MetricLine {
        let percent = ProviderParse.clampPercent(candidate.quota.used / candidate.quota.limit * 100)
        return .progress(
            label: label,
            used: (percent * 10).rounded() / 10,
            limit: 100,
            format: .percent,
            resetsAt: candidate.quota.resetsAt,
            periodDurationMs: candidate.periodMs
        )
    }

    /// "LEVEL_INTERMEDIATE" → "Intermediate".
    private static func plan(_ root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = (membership["level"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        let cleaned = level
            .replacingOccurrences(of: "^LEVEL_", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        let label = cleaned.titleCased(separator: { $0 == " " }, lowercasingTail: true)
        return label.nilIfEmpty
    }
}
