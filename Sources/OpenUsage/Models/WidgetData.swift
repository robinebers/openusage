import Foundation

/// Everything a tile needs to render one metric.
///
/// A metric with a `limit` has a beginning and an end, so it renders as a capsule meter row.
/// Without a `limit` it's an unbounded amount → a single right-aligned text line.
struct WidgetData: Hashable {
    /// Hover note for locally-estimated spend tiles (Codex/Claude/Grok Today / Yesterday / Last 30
    /// Days), whose dollars are imputed from token counts rather than billed.
    static let localEstimateNote = "Estimated locally, so it may be off"
    /// Hover note for Cursor spend tiles, whose spend comes from Cursor's usage-history export.
    static let cursorUsageHistoryNote = "From your Cursor usage history."
    /// Headline shown on a placed tile with no real backing metric (em dash, U+2014).
    static let noDataHeadline = "—"
    /// Subtitle shown on a placed tile with no real backing metric. Copy is intentionally exact.
    static let noDataSubtitle = "No data"

    let title: String          // "Claude 5h", "Cursor credits"
    let icon: IconSource
    let kind: MetricKind
    let used: Double
    var limit: Double?         // nil => unbounded (number tile); cleared when a .values line resolves
    var countSuffix: String?   // e.g. "credits", "requests"
    var valuePrefix: String?   // e.g. "~" for forecasts
    var displayMode: WidgetDisplayMode = .used
    /// Global relative/absolute reset display, stamped by `WidgetDataStore` (like `displayMode`).
    var resetDisplayMode: ResetDisplayMode = .relative
    /// Global "always show pacing" opt-in, stamped by `WidgetDataStore` (like `displayMode`). When on,
    /// the blue/healthy row also shows the even-pace tick and its projection copy. Yellow and red rows
    /// always show the tick when a reset window exists; this toggle only adds it on blue.
    var alwaysShowPacing: Bool = false
    /// Widget descriptor id when this tile is backed by live data (`codex.session`, `claude.session`, …).
    var widgetID: String?
    var resetsAt: Date?
    /// Zero or more future expiry instants surfaced in the row's hover tooltip (Codex rate-limit-reset
    /// credits — one entry per still-available credit). Empty for every other row. Kept as raw `Date`s so
    /// the tooltip formats live and follows the global relative/absolute mode (see `expiryTooltip`).
    var expiriesAt: [Date] = []
    /// Descriptor opt-in marking this as the Codex rate-limit-reset-credits row. When set, the value
    /// column reveals the resets popover on hover (a timeline of each credit's expiry, or an empty
    /// state when none are available) and lights up like the spend rows — so it stays reachable even
    /// at "0 available", where `expiriesAt` is empty. Off for every other row.
    var showsResetExpiries: Bool = false
    /// Names of models this period's spend used that the pricing sources can't price. Their usage is
    /// left out of the displayed total, so the period's figures can be understated.
    /// Drives the label warning triangle and its hover list. Empty for every other row.
    var unknownModels: [String] = []
    /// Period-scoped model spend/tokens for the Today / Yesterday / Last 30 Days hover popover. Nil for
    /// non-spend rows and for periods where the provider has no model-level data.
    var modelBreakdown: ModelUsageBreakdown?
    var periodDurationMs: Int?
    var valueTextOverride: String?
    var subtitleOverride: String?
    var limitNoun: String?     // word after a dollar limit, e.g. "$100 limit" (defaults to "limit")
    /// Fixed trailing word for an unbounded row, e.g. "left" for an extra balance or "spent" for a
    /// spend estimate. When set it replaces the global left/used mode word.
    var unboundedValueWord: String?
    /// Optional source/disclaimer note for locally-estimated tiles. Rendered on the value-side hover,
    /// not beside the left label, so labels stay inert.
    var infoNote: String?
    /// Optional source note for value rows such as Cursor spend history.
    var valueTooltipNote: String?
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
    /// A tray-only unit word appended after this tile's menu-bar value for an unbounded count (e.g. Codex
    /// Rate Limit Resets → "2 resets"). Set by the descriptor, so renaming the tile can't silently drop
    /// the suffix — replaces matching on the tile's title. `nil` for tiles that show the bare value.
    var traySuffix: String?
    /// Session-window meters (Claude/Antigravity 5-hour pools) that read "Not started" when unused.
    /// Set by those descriptors and carried through `WidgetDataStore.resolve`, so the "fresh window"
    /// treatment is a descriptor opt-in rather than a hardcoded widget-ID list in the model.
    var isSessionWindow: Bool = false
    /// Per-day points for a Usage Trend row (empty for every other tile). Set true `isChart` flags the
    /// row so the view draws the sparkline instead of the value layout; `chartNote` is the source line
    /// shown on hover (e.g. "From your Claude usage history (estimated)").
    var isChart: Bool = false
    var chartPoints: [MetricChartPoint] = []
    var chartNote: String?

    var isBounded: Bool { limit != nil }

    var hasModelBreakdown: Bool {
        hasData && isUsagePeriod && !(modelBreakdown?.models.isEmpty ?? true)
    }

    /// `values` projected through `selection` — exactly what this tile shows.
    var selectedValues: [MetricValue] { selection.apply(to: values) }

    var displayedValue: Double {
        guard displayMode == .remaining, let limit else { return used }
        return max(0, limit - used)
    }

    /// Ring fill 0...1. Uses the same rounded value the headline shows, so the ring and the number
    /// never disagree — a value that reads "0%" draws an empty ring instead of a tiny sliver.
    /// Display-mode-dependent: `remaining/limit` when the meter shows "remaining", `used/limit` when
    /// it shows "used". Use `remainingFraction` when the value must mean "remaining" regardless of
    /// display mode (e.g. quota notifications' under-10% check).
    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(roundedDisplayValue / limit, 0), 1)
    }

    /// Remaining share of the limit, 0...1, independent of the used/remaining display mode. Quota
    /// notifications use this for the "under 10% remaining" rule so the alert always reflects actual
    /// remaining, whether the headline shows used or remaining.
    var remainingFraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max((limit - used) / limit, 0), 1)
    }

    /// Severity bands for the meter fill color (see `MeterState.severity`).
    enum MeterSeverity: Hashable {
        case normal, warning, critical
    }

    /// The meter's full visual state, derived once (`meterState(now:)`) so the bar color, the
    /// tick (`paceTick(for:)`), and the label-line warning copy can never contradict each other.
    /// Precedence, highest first: no data → spent → live pace verdict → absolute level bands.
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
        /// shows "~0% spare".) Amber, a "~N% spare" note. `projectedFraction` backs the tooltip's
        /// "% used at reset" copy.
        case closeToLimit(spare: String, projectedFraction: Double)
        /// On course to finish with ≥10% to spare. Blue. By default it carries no decoration; when
        /// "always show pacing" is on it surfaces the projection copy ("~N% left at reset").
        /// `projectedFraction` backs the tooltip's "% left at reset" cushion copy.
        case healthy(projectedFraction: Double)
        /// No reset window to pace against: color from absolute level bands on the share used, no copy.
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
            case .closeToLimit(_, let projectedFraction):
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
    func roundedAtDisplayPrecision(_ value: Double) -> Double {
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

    /// The menu-bar (tray) reading: bounded metrics stay unit-aware (percent meters as %, dollar meters
    /// as compact dollars, count meters as compact counts) while still honoring the global Used/Left
    /// mode through `displayedValue`. Unbounded rows show their selected value compacted through the same
    /// formatter the popover uses. A status badge with no number (e.g. Grok "Disabled") shows its text
    /// rather than a misleading "0".
    var menuBarValue: String {
        guard hasData else { return valueText }
        if let limit, limit > 0 {
            if kind == .percent {
                // Percent is the only bounded unit that should collapse to a tray percentage. Clamp both
                // ends so a provider sample can never print "-5%" or "105%" beside the icon.
                let percent = min(100, max(0, Int((displayedValue / limit * 100).rounded())))
                return "\(percent)%"
            }
            return MetricFormatter.number(displayedValue, kind: kind, style: .tray)
        }
        if let first = selectedValues.first {
            if let traySuffix, first.kind == .count {
                return "\(MetricFormatter.number(first.number, kind: .count, style: .tray)) \(traySuffix)"
            }
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

    /// Color bands for reset-credit expiries: blue normally, amber under a week, red under 48 hours.
    /// A past-due expiry remains critical until the next refresh drops it from the available list.
    static let expiryWarningWindow: TimeInterval = 7 * 24 * 60 * 60
    static let expiryCriticalWindow: TimeInterval = 48 * 60 * 60

    /// Severity band for a single expiry `timeRemaining` seconds out: red under 48h, amber under a
    /// week, blue beyond. Shared by the row's status dot (soonest expiry) and the resets popover's
    /// per-credit dots, so one credit can never read a different color in the two places.
    static func expirySeverity(secondsRemaining: TimeInterval) -> MeterSeverity {
        if secondsRemaining <= expiryCriticalWindow { return .critical }
        if secondsRemaining <= expiryWarningWindow { return .warning }
        return .normal
    }

    /// Visual status for rows carrying reset-credit expiries. Recomputes on the popover's 30s tick because
    /// the row keeps ticking while it carries expiries.
    func expirySeverity(now: Date = Date()) -> MeterSeverity? {
        guard hasData, let soonest = expiriesAt.min() else { return nil }
        return Self.expirySeverity(secondsRemaining: soonest.timeIntervalSince(now))
    }

    /// The available reset-credit count backing a `showsResetExpiries` row (its "N available" figure).
    /// Lets the popover tell "no credits" (empty state) from "credits whose per-credit expiries we
    /// couldn't fetch" — the usage-body fallback carries the count but no expiry list, so `expiriesAt`
    /// is empty while the row still reads e.g. "3 available".
    var resetCreditCount: Int {
        Int((selectedValues.first?.number ?? 0).rounded(.down))
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

    /// True when this period's spend used at least one model the pricing manifest can't price, so its
    /// dollar figure is incomplete. Drives the label warning triangle on the Cursor spend tiles.
    var hasUnknownModels: Bool {
        hasData && !unknownModels.isEmpty
    }

    /// Hover copy for the unknown-model warning triangle: a header naming the problem, then each unpriced
    /// model on its own line. Singular/plural header to read naturally. `nil` when the period priced every
    /// model it used (the common case), so the triangle and its tooltip stay off.
    var unknownModelTooltip: String? {
        guard hasUnknownModels else { return nil }
        let header = unknownModels.count == 1 ? "Unknown model found" : "Unknown models found"
        return ([header] + unknownModels.map { "- \($0)" }).joined(separator: "\n")
    }

    /// Secondary line under an unbounded row's detail (e.g. "on-device estimate"); nil with no real data.
    var unboundedSubtitle: String? {
        guard hasData else { return nil }
        return subtitleOverride
    }

    /// Full, un-abbreviated values for the row's hover tooltip — the exact numbers the compact row
    /// shortens (e.g. "$2,059.07 · 1,506,025,363"). `nil` when nothing is abbreviated and there is no
    /// source note, so a row like "2" or "$30.88 · 772 credits" gets no redundant tooltip.
    var unboundedTooltip: String? {
        guard hasData else { return nil }
        let selected = selectedValues
        guard selected.contains(where: { abs($0.number) >= 1000 }) || unboundedTooltipNote != nil else { return nil }
        return selected.map { MetricFormatter.string(for: $0, style: .full) }.joined(separator: " · ")
    }

    /// Hover text for an unbounded row's **value** (and the expiry-warning icon): the per-credit expiry
    /// breakdown on a reset-credit row, else the exact figures the compact value shortens plus any
    /// source note. `nil` for a small, already-full, non-zero row with no note.
    var unboundedValueTooltip: String? {
        // The reset-credit row's per-credit expiry breakdown takes precedence (it's the whole point of
        // hovering "2 available"); its tiny count never has a figures tooltip anyway.
        if let expiry = expiryTooltip { return expiry }
        if isZeroUsage && isUsagePeriod {
            return (["No usage in this period"] + [unboundedTooltipNote].compactMap { $0 }).joined(separator: "\n")
        }
        if let figures = unboundedTooltip {
            return ([figures] + [unboundedTooltipNote].compactMap { $0 }).joined(separator: "\n")
        }
        // The "no usage" note only fits a spend period (Today / Yesterday / Last 30 Days), where a zero
        // genuinely means nothing was used. A balance row that reads 0 (Codex Rate Limit Resets, an
        // exhausted Extra Usage credit) is depleted, not idle, so it gets no note.
        return nil
    }

    private var unboundedTooltipNote: String? {
        infoNote ?? valueTooltipNote
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
    func format(_ value: Double) -> String {
        MetricFormatter.number(value, kind: kind, style: .full)
    }
}

extension WidgetData {
    /// The neighbor-aware condensing rule, in one place: within a single run of rows (a run never spans
    /// the expand caret — callers segment at that boundary and scan each segment separately), the offsets
    /// of text-only rows that sit directly under another text-only row. A text-only row has no meter fill
    /// (`!isBounded`); a run of them (Today / Yesterday / Last 30 Days) pulls up into one cluster. The
    /// dashboard maps these offsets back to descriptor IDs; the share-card export maps them to flat indices.
    static func condensedTextRowOffsets(in rows: [WidgetData]) -> Set<Int> {
        var offsets = Set<Int>()
        for index in rows.indices.dropFirst() where !rows[index - 1].isBounded && !rows[index].isBounded {
            offsets.insert(index)
        }
        return offsets
    }
}
