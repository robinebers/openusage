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

    /// Pace color (amber/red) is unidentifiable this early — a Monday burst or the first minutes of
    /// a 5-hour session would otherwise always look like a blow-out. Absolute level bands still apply.
    /// Session-scale windows (5h) use this; weekly-scale uses `identifiableWeeklyElapsedFraction`.
    static let identifiableElapsedFraction = 0.25
    /// 25% of a week is only ~42h — Tuesday evening still false-reds on linear. Wait until ~3 days.
    static let identifiableWeeklyElapsedFraction = 0.40
    /// Provider `resetsAt` wanders by 1–2s in the wild (Claude). Cluster / same-window uses this,
    /// not millisecond equality.
    static let windowJitterTolerance: TimeInterval = 5
    /// Same gate on the share used: a 1% whole-percent meter early in the window is not a real burn.
    static let identifiableUsedFraction = 0.05
    /// Same-window used drop of this much is a quota wipe (Anthropic new-model), not noise.
    /// Absolute 5 pts so a 100-limit whole-percent meter ignores 71→70 flicker.
    static let usageWipeUsedFraction = 0.05
    static func usageWipeDrop(limit: Double) -> Double {
        max(5, limit * usageWipeUsedFraction)
    }
    /// When at least two comparable slot remainders exist, red requires this empirical hit rate.
    static let hitRateRedThreshold = 0.75
    /// Last-K completed cycles for the seasonal remaining median.
    static let historyK = 3
    /// Windows at least this long use weekday×hour slots; shorter ones are session-scale (elapsed blend).
    static let weeklyScaleMinimum: TimeInterval = 24 * 60 * 60
    /// Discard a meter's sample history when its cap jumps by this relative amount (plan change).
    static let limitJumpWipeFraction = 0.20
    /// Hard cap per meter after 35-day trim. Hourly weekly path is ~840; this is a safety bound.
    static let maxSamplesPerMeter = 2_500
    /// Coalesce weekly-scale samples to this elapsed width (matches weekday×hour remainder slots).
    static let weeklySampleBucket: TimeInterval = 3600
    /// Coalesce session-scale samples to this elapsed width (matches 10-minute remainder buckets).
    static let sessionSampleBucket: TimeInterval = 600

    /// True when elapsed and used are both far enough along for a pace verdict (amber/red) to be trustworthy.
    static func isIdentifiable(used: Double, limit: Double, elapsed: TimeInterval,
                               periodDuration: TimeInterval) -> Bool {
        guard limit > 0, periodDuration > 0, elapsed >= minimumElapsed(periodDuration: periodDuration) else {
            return false
        }
        let minElapsedFrac = periodDuration >= weeklyScaleMinimum
            ? identifiableWeeklyElapsedFraction
            : identifiableElapsedFraction
        return elapsed / periodDuration >= minElapsedFrac
            && used / limit >= identifiableUsedFraction
    }

    /// Linear current-window extrapolation: `used / elapsed * period`.
    static func linearProjectedUsage(used: Double, elapsed: TimeInterval, periodDuration: TimeInterval) -> Double {
        guard used.isFinite, periodDuration.isFinite, periodDuration > 0, elapsed > 0 else { return max(0, used) }
        let proj = used / elapsed * periodDuration
        return max(used, proj)
    }

    /// End-of-window projection. `remainders` are comparable completed-cycle remaining-at-this-slot
    /// values (same unit as `used`).
    /// - Blends historical slot remainders with live rates using adaptive power weighting
    ///   `w(t) = (elapsed / period)^0.75`, leaning on historical slot remainders early in the window
    ///   and converging to live linear rate later in the window.
    /// - Robust against NaN/Inf, negative inputs, clock skew, and remainder anomalies.
    static func projectUsage(used: Double, elapsed: TimeInterval, periodDuration: TimeInterval,
                             remainders: [Double]) -> Double {
        guard used.isFinite, periodDuration.isFinite, periodDuration > 0 else { return max(0, used) }
        guard used > 0 else { return 0 }
        let safeElapsed = max(0, elapsed)
        guard safeElapsed > 0 else { return used }
        if safeElapsed >= periodDuration { return used }

        let linear = linearProjectedUsage(used: used, elapsed: safeElapsed, periodDuration: periodDuration)
        let cleanRemainders = remainders.filter { $0.isFinite && $0 >= 0 }
        guard cleanRemainders.count >= 2 else { return linear }

        let seasonal = used + median(Array(cleanRemainders.suffix(historyK)))
        let elapsedFraction = min(max(safeElapsed / periodDuration, 0), 1)
        let weight = pow(elapsedFraction, 0.75)
        let blended = (1.0 - weight) * seasonal + weight * linear
        return max(used, blended)
    }

    /// Share of comparable remainders that would land at or over the limit from `used`.
    static func empiricalHitRate(used: Double, limit: Double, remainders: [Double]) -> Double? {
        guard used.isFinite, limit.isFinite, limit > 0 else { return nil }
        let clean = remainders.filter { $0.isFinite && $0 >= 0 }
        guard clean.count >= 2 else { return nil }
        let recent = Array(clean.suffix(historyK))
        let hits = recent.filter { used + $0 >= limit }.count
        return Double(hits) / Double(recent.count)
    }

    static func median(_ values: [Double]) -> Double {
        let clean = values.filter { $0.isFinite }
        guard !clean.isEmpty else { return 0 }
        let sorted = clean.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Full pace evaluation, or `nil` when there's no signal (window not started yet, already reset,
    /// too early in the window for a stable projection, or nothing spent yet). Mirrors
    /// `calculatePaceStatus`, minus its zero-usage "ahead": zero usage carries no burn rate to
    /// project, and the fabricated 0-usage projection surfaced as a tautological "~100% left at
    /// reset" on every untouched meter once Always Show Pacing was on.
    static func evaluate(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                         now: Date = Date(), remainders: [Double] = []) -> Result? {
        guard limit > 0, periodDuration > 0, used > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= minimumElapsed(periodDuration: periodDuration), now < resetsAt else { return nil }

        let projected = projectUsage(used: used, elapsed: elapsed, periodDuration: periodDuration,
                                     remainders: remainders)
        if used >= limit { return Result(status: .behind, projectedUsage: projected) } // maxed → behind

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }      // ≥10% projected to spare
        else if projected <= limit { status = .onTrack }     // lands inside the last 10%
        else if let hitRate = empiricalHitRate(used: used, limit: limit, remainders: remainders),
                remainders.count >= 2, hitRate < hitRateRedThreshold {
            status = .onTrack // projected over, but comparable slots rarely actually hit
        } else {
            status = .behind
        }
        return Result(status: status, projectedUsage: projected)
    }

    /// Projected seconds until the quota is exhausted, but only when we're `behind` and the run-out lands
    /// before the window resets (otherwise there's nothing to warn about). Mirrors `getRunsOutDurationText`.
    static func secondsToRunOut(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                                now: Date = Date(), remainders: [Double] = []) -> TimeInterval? {
        guard isIdentifiable(used: used, limit: limit,
                             elapsed: now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration)),
                             periodDuration: periodDuration),
              let result = evaluate(used: used, limit: limit, resetsAt: resetsAt,
                                    periodDuration: periodDuration, now: now, remainders: remainders),
              result.status == .behind else { return nil }
        let rate = result.projectedUsage / periodDuration   // usage per second at the current burn rate
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate                      // seconds until the remaining quota is gone
        let remaining = resetsAt.timeIntervalSince(now)
        guard eta > 0, eta < remaining else { return nil }
        return eta
    }
}
