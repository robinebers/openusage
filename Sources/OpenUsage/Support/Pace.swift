import Foundation

/// Burn-rate pacing for a bounded metric, ported from the original OpenUsage
/// (`src/lib/pace-status.ts`, `src/lib/pace-tooltip.ts`). Given how much of a quota is spent and how far
/// through the reset window we are, it projects usage at the current rate to the end of the window.
/// This drives the meter's severity color, the amber state's spare marker + "~3% spare" copy, the
/// hover tooltip, and the "Runs out in …" projection.
///
/// Pure logic (no SwiftUI) so it stays unit-testable; `WidgetData` exposes the view-facing strings.
enum Pace {
    enum Status {
        case ahead     // projected to finish with ≥10% of the quota to spare → calm blue
        case onTrack   // projected to land inside the last 10% — cutting it close → amber
        case behind    // projected to blow past the limit before reset → red
    }

    /// Classification plus the projected end-of-period usage (same unit as `used`/`limit`), mirroring the
    /// original's `PaceResult`. `projectedUsage` feeds the tooltip's "% used/left at reset" detail.
    struct Result {
        let status: Status
        let projectedUsage: Double
    }

    /// Minimum time into the reset window before burn-rate projection is meaningful — avoids
    /// dividing by a few seconds of elapsed time on a coarse whole-percent meter.
    static func minimumElapsed(periodDuration: TimeInterval) -> TimeInterval {
        max(60, periodDuration * 0.01)
    }

    /// A rolling usage window whose reset is still a full period away has not started yet — elapsed
    /// time in the window is zero (or still in the future by clock skew). Reliable when `resetsAt`
    /// and `periodDuration` come from the provider (Codex `reset_at` + `limit_window_seconds`,
    /// Claude `resets_at` + the known five-hour session length).
    static func isFreshUsageWindow(resetsAt: Date, periodDuration: TimeInterval, now: Date = Date()) -> Bool {
        guard periodDuration > 0, now < resetsAt else { return false }
        return resetsAt.timeIntervalSince(now) >= periodDuration - 1
    }

    /// Full pace evaluation, or `nil` when there's no signal (window not started yet, already reset,
    /// or too early in the window for a stable projection). Mirrors `calculatePaceStatus`.
    static func evaluate(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                         now: Date = Date()) -> Result? {
        guard limit > 0, periodDuration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= minimumElapsed(periodDuration: periodDuration), now < resetsAt else { return nil }

        if used <= 0 { return Result(status: .ahead, projectedUsage: 0) }   // nothing spent → ahead
        let projected = used / elapsed * periodDuration
        if used >= limit { return Result(status: .behind, projectedUsage: projected) } // maxed → behind

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }      // ≥10% projected to spare
        else if projected <= limit { status = .onTrack }     // lands inside the last 10%
        else { status = .behind }
        return Result(status: status, projectedUsage: projected)
    }

    /// Just the pace classification, or `nil` when there's no signal.
    static func status(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                       now: Date = Date()) -> Status? {
        evaluate(used: used, limit: limit, resetsAt: resetsAt, periodDuration: periodDuration, now: now)?.status
    }

    /// Projected seconds until the quota is exhausted, but only when we're `behind` and the run-out lands
    /// before the window resets (otherwise there's nothing to warn about). Mirrors `getRunsOutDurationText`.
    static func secondsToRunOut(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                                now: Date = Date()) -> TimeInterval? {
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt,
                                    periodDuration: periodDuration, now: now),
              result.status == .behind else { return nil }
        let rate = result.projectedUsage / periodDuration   // usage per second at the current burn rate
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate                      // seconds until the remaining quota is gone
        let remaining = resetsAt.timeIntervalSince(now)
        guard eta > 0, eta < remaining else { return nil }
        return eta
    }
}
