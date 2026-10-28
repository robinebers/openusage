import Foundation

/// Turns `GET /zen/go/v1/usage` into the three Go plan meters. The endpoint reports percent used
/// (same numbers as the OpenCode dashboard) plus an ISO reset time — not dollar spend — so each row
/// is a `.percent` progress meter.
enum OpenCodeUsageMapper {
    /// The account line's plan tag. The usage endpoint only serves Go subscriptions and names no tier.
    static let plan = "Go"

    /// Maximum distance from exactly one full period for a zero-usage rolling reset to count as the
    /// untouched-window placeholder. OpenCode rounds `resetInSec` up to whole seconds and HTTP `Date`
    /// headers carry whole-second precision, so two seconds covers both rounding steps. A session that
    /// starts inside that narrow interval is indistinguishable in one response and can read "Not started"
    /// until the next refresh; widening this tolerance would lengthen that unavoidable stale state.
    static let placeholderResetTolerance: TimeInterval = 2

    static func meterLines(_ response: HTTPResponse, capturedAt: Date = Date()) throws -> [MetricLine] {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }
        // Compare two server-authored instants when possible. This removes Mac clock skew from the
        // placeholder test. A missing or unparseable HTTP Date header is allowed by HTTP, so direct
        // callers and unusual intermediaries fall back to the local response-capture time.
        return try meterLines(body: body, capturedAt: response.date ?? capturedAt)
    }

    static func meterLines(body: [String: Any], capturedAt: Date = Date()) throws -> [MetricLine] {
        guard let usage = body["usage"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        return [
            try window(usage["rolling"], label: "Session", periodMs: MetricPeriod.sessionMs,
                       capturedAt: capturedAt, dropsPlaceholderReset: true),
            try window(usage["weekly"], label: "Weekly", periodMs: MetricPeriod.weekMs, capturedAt: capturedAt),
            try window(usage["monthly"], label: "Monthly", periodMs: MetricPeriod.monthMs, capturedAt: capturedAt)
        ]
    }

    /// The upstream error discriminator (`AuthError`, `EntitlementError`, …), when the body is the
    /// documented `{ type, error: { type, message } }` shape. `nil` for HTML/Cloudflare/empty bodies.
    static func errorType(in response: HTTPResponse) -> String? {
        guard let body = ProviderParse.jsonObject(response.body),
              let error = body["error"] as? [String: Any],
              let type = (error["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty
        else { return nil }
        return type
    }

    /// One window. `dropsPlaceholderReset` is for the rolling session only: with no calls inside the
    /// window there is nothing to roll off, so the API answers `resetsAt = now + 5h` and re-derives it
    /// on every request rather than reporting a real instant. That placeholder means "if you started
    /// now", so it is dropped to `nil` here and the Session row shows no reset. Doing it at capture time
    /// is what makes it sound: the full-period comparison is exact only at the instant the snapshot is
    /// taken, and drifts every second afterwards, so it must not be re-run at render time.
    ///
    /// A window with real usage anchors its reset to the oldest call, so it stays strictly inside the
    /// period and keeps its countdown — including the sub-1% case, where the whole-percent `percent`
    /// field rounds down to 0 and would otherwise read as an unstarted window. Weekly and monthly opt
    /// out: their resets are calendar/billing instants that exist regardless of usage, and early in a
    /// cycle one would sit a near-full period out and be dropped by mistake.
    private static func window(
        _ raw: Any?,
        label: String,
        periodMs: Int,
        capturedAt: Date,
        dropsPlaceholderReset: Bool = false
    ) throws -> MetricLine {
        guard let object = raw as? [String: Any],
              let percent = ProviderParse.number(object["percent"]),
              let resetString = object["resetsAt"] as? String,
              let reportedReset = OpenUsageISO8601.date(from: resetString)
        else {
            throw ProviderError.invalidResponse
        }
        let used = ProviderParse.clampPercent(percent)
        var resetsAt: Date? = reportedReset
        if dropsPlaceholderReset, used == 0 {
            let period = TimeInterval(periodMs) / 1000
            let distanceFromFullPeriod = abs(reportedReset.timeIntervalSince(capturedAt) - period)
            if distanceFromFullPeriod <= placeholderResetTolerance {
                resetsAt = nil
            }
        }
        return .percent(label, used, resetsAt: resetsAt, periodMs: periodMs)
    }
}
