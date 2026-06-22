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
    /// Zero or more future expiry instants surfaced in the row's hover tooltip (Codex rate-limit-reset
    /// credits — one entry per still-available credit). Empty for every other row. Kept as raw `Date`s so
    /// the tooltip formats live and follows the global relative/absolute mode (see `expiryTooltip`).
    var expiriesAt: [Date] = []
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
    /// Raw numbers for an unbounded `.values` row (empty for meters and legacy `.text` rows). The view
    /// formats these at render time instead of reading a baked string — see `unboundedDetail`.
    var values: [MetricValue] = []
    /// Which of `values` this widget renders — cost-only, tokens-only, or the combined `.all`. Set by
    /// the descriptor factory, so one provider row can back several tiles and the mapper stays oblivious.
    var selection: ValueSelection = .all
    /// True only for the Today / Yesterday / Last 30 Days spend tiles, where the row's values accumulate
    /// over a time window so an all-zero reading means "nothing was used." Balance/availability rows
    /// (Codex Rate Limit Resets, an exhausted Extra Usage credit) read zero when *depleted*, not idle, so
    /// they leave this false and never get the "No usage in this period" note. Set by the spend-tile
    /// factory; rides the descriptor sample through `WidgetDataStore.resolve`.
    var isUsagePeriod: Bool = false
    /// Per-day points for a Usage Trend row (empty for every other tile). Set true `isChart` flags the
    /// row so the view draws the sparkline instead of the value layout; `chartNote` is the source line
    /// shown on hover (e.g. "Estimated from local logs at API rates").
    var isChart: Bool = false
    var chartPoints: [MetricChartPoint] = []
    var chartNote: String?

    var isBounded: Bool { limit != nil }

    /// `values` projected through `selection` — exactly what this tile shows.
    var selectedValues: [MetricValue] { selection.apply(to: values) }

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
        /// speak of. Red, flame + the run-out time ("Limit in 3h 45m"). `eta` is `nil` at the float
        /// edge where the run-out lands essentially at the reset, and whenever the projected cushion
        /// rounds to 0%
        /// (≤ limit, so there's no run-out time) — in both cases the flame shows alone rather than a
        /// misleading "0s" or a "~0% spare" amber bar. `projectedFraction` (projected end-of-period
        /// usage ÷ limit) backs the tooltip's overage / "lands at the limit" copy.
        case runningOut(eta: String?, projectedFraction: Double)
        /// Projected to land inside the last 10% — cutting it close — but still with a cushion of at
        /// least 1%. (A cushion that rounds to 0% promotes to `runningOut` instead, so amber never
        /// shows "~0% spare".) Amber, a "~N% spare" note and a tick fencing the spare-width sliver
        /// off at the fill's edge (`tick`, already
        /// Used/Left-aware: used + spare in Used view, so the sliver sits just outside the fill;
        /// remaining − spare in Left view, so it's the last slice of the fill — see
        /// `WidgetRowView.meter`). `projectedFraction` backs the tooltip's "% used at reset" copy.
        case closeToLimit(spare: String, tick: Double, projectedFraction: Double)
        /// On course to finish with ≥10% to spare. Blue, no decoration. `projectedFraction` backs the
        /// tooltip's "% left at reset" cushion copy.
        case healthy(projectedFraction: Double)
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

        /// Hover-tooltip detail shared by the bar, the spare note, and the flame: a short numeric
        /// projection of where pace lands at reset, adding the one figure the row doesn't already
        /// show. Blue → the projected cushion ("~35% left at reset"); amber → projected usage
        /// ("~92% used at reset"), the complement of the visible "~N% spare"; red → the overage
        /// ("~12% over limit at reset"), or "~100% used at reset" when projected to land right at
        /// the limit (the promoted-onTrack case, ≤ limit, so there's no overage). `nil` where there's
        /// no pace story (no data, or a plain absolute-band level); terminal "Limit reached" when spent.
        var tooltip: String? {
            switch self {
            case .noData, .level: return nil
            case .spent: return "Limit reached"
            case .healthy(let projectedFraction):
                let left = Int(((1 - projectedFraction) * 100).rounded())
                return "~\(left)% left at reset"
            case .closeToLimit(_, _, let projectedFraction):
                let used = Int((projectedFraction * 100).rounded())
                return "~\(used)% used at reset"
            case .runningOut(_, let projectedFraction):
                guard projectedFraction > 1 else { return "~100% used at reset" }
                // Floored to 1% so a bar projected even slightly over never reads "~0% over limit".
                let over = max(1, Int(((projectedFraction - 1) * 100).rounded()))
                return "~\(over)% over limit at reset"
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
        if let valueTextOverride { return valueTextOverride }
        // A `.values` row's primary reading is its first selected value; meters and legacy `.text` rows
        // fall through to the bounded/`used` formatting.
        if let first = selectedValues.first {
            return (valuePrefix ?? "") + MetricFormatter.number(first.number, kind: first.kind, style: .row)
        }
        return (valuePrefix ?? "") + format(displayedValue)
    }

    /// The menu-bar (tray) reading: a bounded metric glances as a percentage (regardless of unit, so
    /// Cursor Credits reads "67%", not "$12,923"); an unbounded one shows its selected value compacted
    /// (1.2M tokens / $3.4K) through the same formatter the popover uses. A status badge with no number
    /// (e.g. Grok "Disabled") shows its text rather than a misleading "0".
    var menuBarValue: String {
        guard hasData else { return valueText }
        if let limit, limit > 0 {
            let percent = max(0, Int((displayedValue / limit * 100).rounded()))
            return "\(percent)%"
        }
        if let first = selectedValues.first {
            return MetricFormatter.string(for: first, style: .tray)
        }
        if let valueTextOverride { return valueTextOverride }
        let number = MetricFormatter.number(displayedValue, kind: kind, style: .tray)
        if kind == .count, let countSuffix { return "\(number) \(countSuffix)" }
        return number
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
        let selected = selectedValues
        if !selected.isEmpty {
            // One value: a lone dollar amount takes the widget's trailing word ("$4.08 spent",
            // "$1,503 left"); any other single value carries its own unit label ("1.2M tokens",
            // "2 available"). Several values join into the combined reading ("$4.08 · 1.2M tokens").
            if selected.count == 1 {
                let value = selected[0]
                if value.kind == .dollars, let word = unboundedValueWord {
                    return "\(MetricFormatter.number(value.number, kind: .dollars, style: .row)) \(word)"
                }
                return MetricFormatter.string(for: value, style: .row)
            }
            return selected.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · ")
        }
        // Legacy unbounded `.text` rows (e.g. Devin extra balance): "<value> <suffix> <word>".
        let word = unboundedValueWord ?? displayMode.label.lowercased()
        if kind == .count, let countSuffix {
            return "\(valueText) \(countSuffix) \(word)"
        }
        return "\(valueText) \(word)"
    }

    /// A soonest-expiry inside this window flips the row to a warning state (the ⚠ triangle next to the
    /// count) — a reset credit you're about to lose if you don't use it.
    static let expiryWarningWindow: TimeInterval = 24 * 60 * 60

    /// True when the soonest still-available reset credit expires within `expiryWarningWindow` (a past-due
    /// one counts too). Drives the row's warning triangle; recomputes on the popover's 30s tick because
    /// the row keeps ticking while it carries expiries.
    var hasImminentExpiry: Bool {
        guard hasData, let soonest = expiriesAt.min() else { return false }
        return soonest.timeIntervalSince(Date()) <= Self.expiryWarningWindow
    }

    /// Hover tooltip for a row carrying expiry instants (the Codex reset-credit row, "2 available"):
    /// when each credit's reset will expire, following the global relative/absolute mode. One credit →
    /// "Reset expires in 12d 18h" (relative) / "Reset expires Feb 15 at 3:45 PM" (absolute); several →
    /// a numbered list under a "Resets expire in:" / "Resets expire:" header. `nil` when the row carries
    /// no expiries, so non-reset rows fall through to their figures tooltip.
    var expiryTooltip: String? {
        guard hasData, !expiriesAt.isEmpty else { return nil }
        let now = Date()
        let sorted = expiriesAt.sorted()
        if sorted.count == 1 {
            return Formatters.deadlineLabel("Reset expires", at: sorted[0], mode: resetDisplayMode, now: now)
        }
        let entries = sorted.enumerated().compactMap { index, date -> String? in
            Formatters.whenLabel(at: date, mode: resetDisplayMode, now: now).map { "\(index + 1). \($0)" }
        }
        guard !entries.isEmpty else { return nil }
        // The header carries the verb; "in" only fits the relative durations beneath it (absolute
        // entries already read "Feb 15 at 3:45 PM").
        let header = resetDisplayMode == .relative ? "Resets expire in:" : "Resets expire:"
        return ([header] + entries).joined(separator: "\n")
    }

    /// Secondary line under an unbounded row's detail (e.g. "on-device estimate"); nil with no real data.
    var unboundedSubtitle: String? {
        guard hasData else { return nil }
        return subtitleOverride
    }

    /// Full, un-abbreviated values for the row's hover tooltip — the exact numbers the compact row
    /// shortens (e.g. "$2,059.07 · 1,506,025,363"). `nil` when nothing is abbreviated (every value is
    /// already shown in full), so a row like "2" or "$30.88 · 772 credits" gets no redundant tooltip.
    var unboundedTooltip: String? {
        guard hasData else { return nil }
        let selected = selectedValues
        guard selected.contains(where: { abs($0.number) >= 1000 }) else { return nil }
        return selected.map { MetricFormatter.string(for: $0, style: .full) }.joined(separator: " · ")
    }

    /// True for a zero-usage period — has data, but every selected value is zero (a row reading
    /// "$0.00 · 0 tokens"). Distinct from "no data" and from small non-zero usage, so the row can show
    /// a "no usage" note rather than a figures reveal.
    var isZeroUsage: Bool {
        guard hasData else { return false }
        let selected = selectedValues
        return !selected.isEmpty && selected.allSatisfy { $0.number == 0 }
    }

    var resetLabel: String? {
        guard let resetsAt else { return nil }
        return Formatters.resetRelativeLabel(until: resetsAt)
    }

    /// Bounded headline / legacy `.text` formatting, delegated to the shared formatter so the popover
    /// and the tray always agree. Unbounded `.values` rows format their values directly (`unboundedDetail`).
    private func format(_ value: Double) -> String {
        MetricFormatter.number(value, kind: kind, style: .full)
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
                return .healthy(projectedFraction: result.projectedUsage / ctx.limit)
            case .onTrack:
                let projected = result.projectedUsage / ctx.limit
                let spare = Int(((1 - projected) * 100).rounded())
                // Projected to land essentially at the limit: the cushion rounds to nothing, so an
                // amber "~0% spare" note + a zero-width tick would contradict the headline's
                // remaining %. Promote to the red run-out state instead — there's no
                // run-out-before-reset time (projection ≤ limit), so the flame stands alone and the
                // tooltip reads "~100% used at reset", exactly `runningOut`'s documented float-edge meaning.
                guard spare >= 1 else { return .runningOut(eta: nil, projectedFraction: projected) }
                let usedShare = used / ctx.limit
                let tick = displayMode == .remaining ? projected - usedShare
                                                     : usedShare + (1 - projected)
                return .closeToLimit(spare: "~\(spare)% spare", tick: tick, projectedFraction: projected)
            case .behind:
                let eta = Pace.secondsToRunOut(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                               periodDuration: ctx.period, now: now)
                    .flatMap { Formatters.deadlineLabel("Limit", at: now.addingTimeInterval($0),
                                                        mode: resetDisplayMode, now: now) }
                return .runningOut(eta: eta, projectedFraction: result.projectedUsage / ctx.limit)
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
