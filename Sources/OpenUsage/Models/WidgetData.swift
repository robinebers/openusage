import Foundation

/// Everything a tile needs to render one metric.
///
/// A metric with a `limit` has a beginning and an end, so it renders as a capsule meter row.
/// Without a `limit` it's an unbounded amount → a single right-aligned text line.
struct WidgetData: Hashable {
    /// Hover note for the ⓘ shown next to the label on ccusage-based spend tiles (Codex/Claude Today /
    /// Yesterday / Last 30 Days), whose dollars are imputed locally from token counts rather than billed.
    static let ccusageEstimateNote = "Estimated locally, so it may be off."
    /// Headline shown on a placed tile with no real backing metric (em dash, U+2014).
    static let noDataHeadline = "—"
    /// Subtitle shown on a placed tile with no real backing metric. Copy is intentionally exact.
    static let noDataSubtitle = "No data"

    let title: String          // "Claude 5h", "Cursor credits"
    let icon: IconSource
    let kind: MetricKind
    let used: Double
    let limit: Double?         // nil => unbounded (number tile)
    var countSuffix: String?   // e.g. "credits", "requests"
    var valuePrefix: String?   // e.g. "~" for forecasts
    var displayMode: WidgetDisplayMode = .used
    /// Global relative/absolute reset display, stamped by `WidgetDataStore` (like `displayMode`).
    var resetDisplayMode: ResetDisplayMode = .relative
    var resetsAt: Date?
    var periodDurationMs: Int?
    var valueTextOverride: String?
    var subtitleOverride: String?
    var limitNoun: String?     // word after a dollar limit, e.g. "$100 limit" (defaults to "limit")
    /// Fixed trailing word for an unbounded row, e.g. "left" for an extra balance or "spent" for a
    /// spend estimate. When set it replaces the global left/used mode word.
    var unboundedValueWord: String?
    /// Optional disclaimer shown as a small trailing ⓘ (with a hover tooltip) right after the value, used
    /// for locally-estimated tiles instead of a separate subtitle line.
    var infoNote: String?
    /// Descriptor opt-in: render the provider's `.text` line verbatim as the row's right-aligned detail
    /// (e.g. Codex Credits "$32.84 · 821 credits") instead of reformatting it as "<value> <word>". The
    /// numeric part is still parsed into `used` so the menu bar keeps its compact value.
    var preservesRawText: Bool = false
    /// False when no real provider metric backs this tile. The view then shows a "No data" state
    /// instead of the descriptor's placeholder sample numbers. True for real data and gallery samples.
    var hasData: Bool = true

    var isBounded: Bool { limit != nil }

    var displayedValue: Double {
        guard displayMode == .remaining, let limit else { return used }
        return max(0, limit - used)
    }

    /// Ring fill 0...1. Uses the same rounded value the headline shows, so the ring and the number
    /// never disagree — a value that reads "0%" draws an empty ring instead of a tiny sliver.
    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(roundedDisplayValue / limit, 0), 1)
    }

    /// Severity bands for the meter fill color (see `MeterState.severity`).
    enum MeterSeverity: Hashable {
        case normal, warning, critical
    }

    /// The meter's full visual state, derived once (`meterState(now:)`) so the bar color, the
    /// amber tick, and the label-line warning copy can never contradict each other. Precedence,
    /// highest first: no data → spent → live pace verdict → absolute level bands. Each case owns
    /// exactly the data its rendering needs, so impossible combinations (a tick on a red bar, a
    /// run-out time with no flame) can't be expressed.
    enum MeterState: Hashable {
        /// No real metric backs the tile — gray, empty track, no copy.
        case noData
        /// Spent to nothing the user can see: a real zero, or a remainder so small it rounds to
        /// "0" at the headline's precision ("0% left", "$0.00", "0 credits"). Red, flame + "Limit
        /// reached". Outranks the pace verdict — a visibly empty bar is never a calmer color.
        case spent
        /// Projected to run out before the reset, or to land right at the limit with no cushion to
        /// speak of. Red, flame + the bare run-out time. `eta` is `nil` at the float edge where the
        /// run-out lands essentially at the reset, and whenever the projected cushion rounds to 0%
        /// (≤ limit, so there's no run-out time) — in both cases the flame shows alone rather than a
        /// misleading "0s" or a "~0% spare" amber bar.
        case runningOut(eta: String?)
        /// Projected to land inside the last 10% — cutting it close — but still with a cushion of at
        /// least 1%. (A cushion that rounds to 0% promotes to `runningOut` instead, so amber never
        /// shows "~0% spare".) Amber, a "~N% spare" note and a tick fencing the spare-width sliver
        /// off at the fill's edge (`tick`, already
        /// Used/Left-aware: used + spare in Used view, so the sliver sits just outside the fill;
        /// remaining − spare in Left view, so it's the last slice of the fill — see
        /// `WidgetRowView.meter`).
        case closeToLimit(spare: String, tick: Double)
        /// On course to finish with ≥10% to spare. Blue, no decoration.
        case healthy
        /// No pace signal to project (no reset window, or <5% of it elapsed): color from the
        /// absolute level bands on the share used, no copy.
        case level(MeterSeverity)

        /// Bar fill severity, or `nil` for `noData` (the track stays gray).
        var severity: MeterSeverity? {
            switch self {
            case .noData: return nil
            case .spent, .runningOut: return .critical
            case .closeToLimit: return .warning
            case .healthy: return .normal
            case .level(let severity): return severity
            }
        }

        /// Hover-tooltip verdict shared by the bar and the warning copy; `nil` where there's
        /// nothing to add (no data, or a plain absolute-band level with no pace story).
        var tooltip: String? {
            switch self {
            case .noData, .level: return nil
            case .spent: return "Limit reached"
            case .runningOut: return Pace.Status.behind.statusText
            case .closeToLimit: return Pace.Status.onTrack.statusText
            case .healthy: return Pace.Status.ahead.statusText
            }
        }
    }

    /// `displayedValue` rounded the same way `format(_:)` rounds it for the headline text.
    private var roundedDisplayValue: Double {
        roundedAtDisplayPrecision(displayedValue)
    }

    /// Rounds a value to the precision this kind shows in the headline — whole percent, one-decimal
    /// count, or cents — so the meter geometry and the spent check never disagree with the printed
    /// number. (A value that reads "0%" must register as zero, not a hairline sliver.)
    private func roundedAtDisplayPrecision(_ value: Double) -> Double {
        switch kind {
        case .percent: return value.rounded()
        case .count: return (value * 10).rounded() / 10
        case .dollars: return (value * 100).rounded() / 100
        }
    }

    /// Primary value string (menu bar, unbounded tiles, the Add-Widget gallery). Returns the no-data
    /// marker when no real metric backs the tile, so no surface can print the descriptor's placeholder
    /// sample numbers as if they were measured usage.
    var valueText: String {
        guard hasData else { return Self.noDataHeadline }
        return valueTextOverride ?? (valuePrefix ?? "") + format(displayedValue)
    }

    /// Large headline on bounded tiles (e.g. `95% left`, `5% used`).
    var boundedHeadline: String {
        if let valueTextOverride {
            return valueTextOverride
        }
        // The unit (e.g. "credits") belongs in boundedSubtitle; the headline carries the mode word.
        // `WidgetDisplayMode.label` is the single source for "Used"/"Left", so there's no second copy.
        return "\(valueText) \(displayMode.label.lowercased())"
    }

    /// Subtitle under the bounded headline (reset timing or limit context).
    var boundedSubtitle: String? {
        if let subtitleOverride {
            return subtitleOverride
        }
        if let resetLabel {
            return resetLabel
        }
        // Any cycle-based metric (e.g. requests) shows its reset cadence when no exact reset date exists.
        if let periodDurationMs,
           let duration = Formatters.compactDuration(TimeInterval(periodDurationMs) / 1000) {
            return "Resets in \(duration)"
        }
        switch kind {
        case .percent:
            return nil
        case .dollars:
            // Mirror the original OpenUsage panel: a bounded dollar metric's secondary line reads
            // "$<limit> limit" — no "of" prefix, and cents only when the limit isn't a whole dollar.
            guard let limit else { return nil }
            let digits = limit.rounded() == limit ? 0 : 2
            let amount = Formatters.currency(limit, fractionDigits: digits)
            return "\(amount) \(limitNoun ?? "limit")"
        case .count:
            // The unit (e.g. "credits") shows whether the count is bounded or a plain balance.
            return countSuffix
        }
    }

    /// View-facing headline for the tile: the single source the tile renders, unifying bounded and
    /// unbounded value strings. Shows an em dash when no real metric backs the tile.
    var headline: String {
        guard hasData else { return Self.noDataHeadline }
        return isBounded ? boundedHeadline : valueText
    }

    /// View-facing caption under the headline (kept visible — no tooltips). Shows "No data" when no
    /// real metric backs the tile; otherwise the metric's reset/limit context.
    var subtitle: String? {
        guard hasData else { return Self.noDataSubtitle }
        return boundedSubtitle
    }

    /// Right-aligned descriptive line for an unbounded row (no bar): just "<value> <word>". The word is
    /// `unboundedValueWord` when set (extras always read "1,503 left", spend rows "$12.34 spent");
    /// otherwise it falls back to the global left/used mode word.
    var unboundedDetail: String {
        guard hasData else { return Self.noDataSubtitle }
        if let valueTextOverride { return valueTextOverride }
        let word = unboundedValueWord ?? displayMode.label.lowercased()
        if kind == .count, let countSuffix {
            return "\(valueText) \(countSuffix) \(word)"
        }
        return "\(valueText) \(word)"
    }

    /// Secondary line under an unbounded row's detail (e.g. "on-device estimate"); nil with no real data.
    var unboundedSubtitle: String? {
        guard hasData else { return nil }
        return subtitleOverride
    }

    var resetLabel: String? {
        guard let resetsAt else { return nil }
        return Formatters.resetRelativeLabel(until: resetsAt)
    }

    private func format(_ value: Double) -> String {
        switch kind {
        case .percent:
            return "\(Int(value.rounded()))%"
        case .dollars:
            // Always show cents. A spend estimate of $180.17 must read "$180.17", never "$180" — dropping
            // the cents for amounts ≥ $100 made our estimates look wrong next to tools that show cents.
            return Formatters.currency(value, fractionDigits: 2)
        case .count:
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
        }
    }
}

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

    /// The meter's full visual state for `now` — the single source the row's color, amber tick,
    /// and warning copy all read from, so they can't drift apart. Precedence, highest first:
    ///
    /// 1. **No data** → gray, empty.
    /// 2. **Spent** → red + "Limit reached", whenever the remainder rounds to zero at the
    ///    headline's precision (a visibly empty bar always reads spent, pace aside).
    /// 3. **Live pace verdict** (a reset window with ≥5% elapsed): blue `healthy` while ≥10% is
    ///    projected to spare, amber `closeToLimit` (with the spare copy + tick) when projected
    ///    inside the last 10% *with a cushion of at least 1%*, red `runningOut` when projected to
    ///    blow past the limit before reset (with the run-out time) or to land right at it (cushion
    ///    rounds to 0% → flame alone, no time). So a half-full bar burning twice the sustainable
    ///    rate is already red, a bar projected to finish with nothing to spare is red rather than a
    ///    misleading "~0% spare" amber, and a nearly-drained bar coasting to the reset stays blue.
    /// 4. **Absolute level bands** (no window to project against): yellow once 80% of the limit is
    ///    used, red once 10% or less is left, rounded to the whole percent the headline shows.
    ///
    /// Every band keys off the share *used*, never the displayed fraction, so the color and copy
    /// don't flip with the Used/Left toggle. Only the amber tick adjusts with the toggle, keeping
    /// the spare-width sliver it splits off attached to the fill in both views.
    func meterState(now: Date = Date()) -> MeterState {
        guard hasData, let limit, limit > 0 else { return hasData ? .level(.normal) : .noData }
        if roundedAtDisplayPrecision(limit - used) <= 0 { return .spent }

        if let ctx = paceContext,
           let result = Pace.evaluate(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                      periodDuration: ctx.period, now: now) {
            switch result.status {
            case .ahead:
                return .healthy
            case .onTrack:
                let projected = result.projectedUsage / ctx.limit
                let spare = Int(((1 - projected) * 100).rounded())
                // Projected to land essentially at the limit: the cushion rounds to nothing, so an
                // amber "~0% spare" note + a zero-width tick would contradict the headline's
                // remaining %. Promote to the red run-out state instead — there's no
                // run-out-before-reset time (projection ≤ limit), so the flame stands alone with the
                // "Will reach limit" verdict, exactly `runningOut`'s documented float-edge meaning.
                guard spare >= 1 else { return .runningOut(eta: nil) }
                let usedShare = used / ctx.limit
                let tick = displayMode == .remaining ? projected - usedShare
                                                     : usedShare + (1 - projected)
                return .closeToLimit(spare: "~\(spare)% spare", tick: tick)
            case .behind:
                let eta = Pace.secondsToRunOut(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                               periodDuration: ctx.period, now: now)
                    .flatMap { Formatters.bareDeadline(at: now.addingTimeInterval($0),
                                                       mode: resetDisplayMode, now: now) }
                return .runningOut(eta: eta)
            }
        }

        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 80 { return .level(.warning) }
        return .level(.normal)
    }

    /// Trailing text on the bounded primary row, reset-display-mode aware. Priority mirrors
    /// `boundedSubtitle`, but a concrete reset honors `resetDisplayMode` (relative ⟷ absolute).
    var boundedTrailingText: String? {
        guard hasData else { return Self.noDataSubtitle }
        if let subtitleOverride { return subtitleOverride }
        if let resetsAt {
            return resetDisplayMode == .absolute
                ? Formatters.resetAbsoluteLabel(at: resetsAt)
                : Formatters.resetRelativeLabel(until: resetsAt)
        }
        return boundedSubtitle // period cadence / dollar limit / count suffix — nothing to flip
    }

    /// True when the bounded primary row's trailing text is a concrete reset countdown (so the row makes
    /// it the clickable toggle). False for limit/suffix context with no real reset date.
    var hasResetLabel: Bool { hasData && subtitleOverride == nil && resetsAt != nil }

    /// Hover tooltip for the reset label: the *opposite* format from what's shown, mirroring the
    /// original's `formatResetTooltipText`. `nil` when there's no concrete reset.
    var resetTooltip: String? {
        guard hasResetLabel, let resetsAt else { return nil }
        return resetDisplayMode == .absolute
            ? Formatters.resetRelativeLabel(until: resetsAt)
            : Formatters.resetAbsoluteLabel(at: resetsAt)
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
