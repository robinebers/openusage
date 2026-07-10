import Foundation

// MARK: - Pace (meter state)

extension WidgetData {
    /// The inputs pacing needs, present only for a bounded metric with a known reset window. `nil`
    /// short-circuits the live pace verdict (the bar falls back to absolute level bands)
    /// (e.g. unbounded rows, no-data rows, rows whose reset/period cadence is unknown).
    private var paceContext: (limit: Double, resetsAt: Date, period: TimeInterval)? {
        guard hasData, let limit, limit > 0, let resetsAt,
              let periodDurationMs, periodDurationMs > 0 else { return nil }
        return (limit, resetsAt, TimeInterval(periodDurationMs) / 1000)
    }

    /// Whether this metric has the limit, reset, and period context required for pace alerts. `.spent`
    /// is visually identical with or without a reset, so notification logic uses this explicit bit to
    /// avoid treating a plain exhausted balance as projected to run out before a reset.
    var hasPaceContext: Bool { paceContext != nil }

    /// The meter's full visual state for `now` — the single source the row's color, amber tick,
    /// and warning copy all read from, so they can't drift apart. Precedence, highest first:
    ///
    /// 1. **No data** → gray, empty.
    /// 2. **Spent** → red + "Limit reached", whenever the remainder rounds to zero at the
    ///    headline's precision (a visibly empty bar always reads spent, pace aside).
    /// 3. **Live pace verdict** (a reset window): blue `healthy` while ≥10% is projected to spare,
    ///    amber `closeToLimit` (with the spare copy) when projected inside the last 10% *with a
    ///    cushion of at least 1%*, red `runningOut` when projected to blow past the limit before reset
    ///    (with the run-out time) or to land right at it (cushion rounds to 0% → flame alone, no time).
    /// 4. **Absolute level bands** (no window to project against): yellow once 80% of the limit is
    ///    used, red once 10% or less is left, rounded to the whole percent the headline shows.
    ///
    /// Every band keys off the share *used*, never the displayed fraction, so the color and copy
    /// don't flip with the Used/Left toggle. The even-pace tick (`paceTick(for:)`) is independent:
    /// yellow and red always show it when a reset window exists; blue only with "always show pacing".
    func meterState(now: Date = Date()) -> MeterState {
        guard hasData, let limit, limit > 0 else { return hasData ? .level(.normal) : .noData }
        if roundedAtDisplayPrecision(limit - used) <= 0 { return .spent }
        // A "Not started" session has nothing to pace yet — present a calm bar with no projection
        // copy or tick, so the bar and its hover never contradict the trailing "Not started" label.
        if isFreshSessionWindow(now: now) { return absoluteLevelState(used: used, limit: limit) }

        if let ctx = paceContext,
           let result = Pace.evaluate(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                      periodDuration: ctx.period, now: now) {
            switch result.status {
            case .ahead:
                return .healthy(projectedFraction: result.projectedUsage / ctx.limit)
            case .onTrack:
                // A whole-percent 1% reading at the projection gate can land exactly on the limit.
                // Keep the same near-empty safeguard as `.behind` so it never becomes a red alarm.
                guard used / ctx.limit >= 0.05 else { return absoluteLevelState(used: used, limit: limit) }
                let projected = result.projectedUsage / ctx.limit
                let spare = Int(((1 - projected) * 100).rounded())
                guard spare >= 1 else { return .runningOut(eta: nil, projectedFraction: projected) }
                return .closeToLimit(spare: "~\(spare)% spare", projectedFraction: projected)
            case .behind:
                // Coarse whole-percent meters can read 1% used very early in a window; linear
                // extrapolation then projects a bogus blow-out while the headline still shows ~99%
                // left. When >95% of the quota clearly remains (used below
                // 5%), distrust the projection entirely and use the absolute level bands instead — a
                // calm bar with no projection copy, never a fabricated "~N% left at reset" cushion.
                guard used / ctx.limit >= 0.05 else { return absoluteLevelState(used: used, limit: limit) }
                let eta = Pace.secondsToRunOut(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                               periodDuration: ctx.period, now: now)
                    .flatMap { Formatters.deadlineLabel("Limit", at: now.addingTimeInterval($0),
                                                        mode: resetDisplayMode, now: now) }
                return .runningOut(eta: eta, projectedFraction: result.projectedUsage / ctx.limit)
            }
        }

        return absoluteLevelState(used: used, limit: limit)
    }

    /// Color from the share used when there's no trustworthy pace projection (no reset window, or a
    /// projection deliberately distrusted near-empty): yellow at 80% used, red at 90%, blue below.
    /// Carries no projection copy or tick — a plain level reading.
    private func absoluteLevelState(used: Double, limit: Double) -> MeterState {
        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 80 { return .level(.warning) }
        return .level(.normal)
    }

    /// Even-pace tick position on the bar (0...1), or `nil` when hidden. Always the elapsed fraction
    /// of the reset window, framed like the fill (Used view → share used at an even burn; Left view →
    /// share remaining). Yellow and red pace states always show it; blue `healthy` only when
    /// `alwaysShowPacing` is on. Spent, no-data, and rows without a reset window never show a tick.
    func paceTick(for state: MeterState, now: Date = Date()) -> Double? {
        switch state {
        case .spent, .noData, .level: return nil
        case .healthy: guard alwaysShowPacing else { return nil }
        case .closeToLimit, .runningOut: break
        }
        guard let ctx = paceContext else { return nil }
        let windowStart = ctx.resetsAt.addingTimeInterval(-ctx.period)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= Pace.minimumElapsed(periodDuration: ctx.period), now < ctx.resetsAt else { return nil }
        let elapsedFraction = min(max(elapsed / ctx.period, 0), 1)
        return displayMode == .remaining ? 1 - elapsedFraction : elapsedFraction
    }

    /// Trailing text on the bounded primary row, reset-display-mode aware. Priority mirrors
    /// `boundedSubtitle`, but a concrete reset honors `resetDisplayMode` (relative ⟷ absolute).
    /// Claude and Antigravity session rows show "Not started" while the rolling window has not begun.
    func boundedTrailingText(now: Date = Date()) -> String? {
        guard hasData else { return Self.noDataSubtitle }
        if let subtitleOverride { return subtitleOverride }
        if isFreshSessionWindow(now: now) { return "Not started" }
        if let resetsAt {
            return resetDisplayMode == .absolute
                ? Formatters.resetAbsoluteLabel(at: resetsAt, now: now)
                : Formatters.resetRelativeLabel(until: resetsAt, now: now)
        }
        return boundedSubtitle // period cadence / dollar limit / count suffix — nothing to flip
    }

    /// Claude and Antigravity session meters only: a "Not started" state for the current window
    /// when nothing has been spent in it yet. Driven by frozen usage (`used == 0`), not a window-timing
    /// read — the `resetsAt - now ≈ full period` test is only valid the instant the snapshot is captured,
    /// then drifts every second until the next refresh, which split the headline from the label (headline
    /// "100% left" while the label fell back to "Resets in 5h"). Usage is the stable, snapshot-consistent
    /// signal: providers that report 0 utilization directly remain at 0, and Antigravity's mapper rounds
    /// its fraction-derived percent (so a pool under ~0.5% used also reads 0). Codex percentages are
    /// preserved verbatim, so a reported 1% is not treated as "Not started."
    /// Still gated on `now < resetsAt`: once the reset has passed the snapshot is stale, so we drop the
    /// "Not started" claim and let the row fall back to the normal "Resets soon"/countdown formatting.
    func isFreshSessionWindow(now: Date = Date()) -> Bool {
        guard isSessionWindow, hasData, limit != nil, let resetsAt, used <= 0 else { return false }
        return now < resetsAt
    }

    /// True when the bounded primary row's trailing text is a concrete reset countdown (so the row makes
    /// it the clickable toggle). False for limit/suffix context, fresh session windows, or no reset date.
    func hasResetLabel(now: Date = Date()) -> Bool {
        hasData && subtitleOverride == nil && resetsAt != nil && !isFreshSessionWindow(now: now)
    }

    /// Hover copy explaining the "Not started" trailing label: the rolling session window only begins
    /// once you send your first message, so there's no live countdown to show yet.
    static let freshSessionTooltip = "Sessions start after you send your first message."

    /// Hover tooltip for the reset label: the *opposite* format from what's shown, mirroring the
    /// original's `formatResetTooltipText`. A fresh ("Not started") session explains itself instead of
    /// showing a reset time, since the window hasn't begun counting down.
    func resetTooltip(now: Date = Date()) -> String? {
        if isFreshSessionWindow(now: now) { return Self.freshSessionTooltip }
        guard hasResetLabel(now: now), let resetsAt else { return nil }
        return resetDisplayMode == .absolute
            ? Formatters.resetRelativeLabel(until: resetsAt, now: now)
            : Formatters.resetAbsoluteLabel(at: resetsAt, now: now)
    }

    /// True when the bounded headline is a flippable Used/Left reading (so the row makes it the
    /// clickable meter-style toggle). False for unbounded rows, overridden values, and no-data rows.
    var hasMeterStyleToggle: Bool {
        hasData && isBounded && valueTextOverride == nil
    }

    /// Hover tooltip for the bounded headline: the *opposite* meter style from what's shown
    /// (e.g. headline "95% left" → tooltip "5% used"), mirroring `resetTooltip`'s flip pattern.
    var meterStyleTooltip: String? {
        guard hasMeterStyleToggle, let limit else { return nil }
        let opposite = displayMode == .remaining ? used : max(0, limit - used)
        let word = (displayMode == .remaining ? WidgetDisplayMode.used : .remaining).label.lowercased()
        return "\((valuePrefix ?? "") + format(opposite)) \(word)"
    }
}
