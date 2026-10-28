import Foundation

/// Everything a row needs to render one metric.
///
/// A metric with a `limit` has a beginning and an end, so it renders as a bar with its value.
/// Without a `limit` it's an unbounded amount: a single right-aligned value.
struct WidgetData: Hashable {
    /// The value a row shows when no real metric backs it (em dash, U+2014).
    static let noDataValue = "—"
    /// The detail an unbounded row shows when no real metric backs it.
    static let noDataDetail = "No data"

    let title: String          // "Claude 5h", "Cursor credits"
    let kind: MetricKind
    let used: Double
    var limit: Double?         // nil => unbounded; cleared when a .values line resolves
    var displayMode: WidgetDisplayMode = .used
    /// Global relative/absolute reset display, stamped by `WidgetDataStore` (like `displayMode`).
    var resetDisplayMode: ResetDisplayMode = .relative
    var resetsAt: Date?
    /// Zero or more future expiry instants listed in the resets row's popover (Claude and Codex
    /// rate-limit resets — one entry per still-available credit). Empty for every other row. Kept as raw
    /// `Date`s so the popover formats live and follows the global relative/absolute mode.
    var expiriesAt: [Date] = []
    /// Descriptor opt-in marking this as the Claude or Codex rate-limit-resets row. When set, the row's
    /// hover popover is the resets timeline (each credit's expiry, where one is claimed) instead of the
    /// account's resets. Off for every other row.
    var showsResetExpiries: Bool = false
    var periodDurationMs: Int?
    var valueTextOverride: String?
    /// Fixed trailing word for an unbounded row, e.g. "left" for an extra balance.
    var unboundedValueWord: String?
    /// False when no real provider metric backs this row. The view then shows a "No data" state
    /// instead of the descriptor's placeholder template numbers. True for real data and direct fixtures.
    var hasData: Bool = true
    /// Raw numbers for an unbounded `.values` row (empty for meters). The view
    /// formats these at render time instead of reading a baked string — see `unboundedDetail`.
    var values: [MetricValue] = []
    /// A tray-only unit word appended after this row's menu-bar value for an unbounded count (e.g. Codex
    /// Rate Limit Resets → "2 resets"). Set by the descriptor, so renaming the row can't silently drop
    /// the suffix — replaces matching on the row's title. `nil` for rows that show the bare value.
    var traySuffix: String?
    /// Session-window meters (Claude/OpenCode rolling 5-hour pools, Antigravity's pools) that show a full
    /// bar and no reset while the window hasn't begun — the value names the signal that detects that state,
    /// because the providers report fresh windows differently (see `SessionStartSignal`). Set by those
    /// descriptors and carried through `WidgetDataStore.resolve`, so the treatment is a descriptor
    /// opt-in rather than a hardcoded widget-ID list in the model. `nil` for every other row.
    var sessionStartSignal: SessionStartSignal?

    /// How a session-window meter tells a not-yet-started window from an in-flight one.
    enum SessionStartSignal: Hashable {
        /// Zero usage is the fresh signal. Antigravity reports a reset instant even for an untouched
        /// window and its mapper rounds the fresh pool's fraction-derived percent to 0, so `used == 0`
        /// is what marks the window as fresh.
        case zeroUsage
        /// A missing reset date is the fresh signal: by the time a row carries one, a reset instant
        /// means the window started. Claude's five-hour block is created by the first message, so it
        /// simply reports no `resets_at` until then; OpenCode does report a placeholder for an untouched
        /// window, which `OpenCodeUsageMapper` drops at capture time. Zero usage is NOT trusted here:
        /// both APIs report utilization in whole percents, so an in-flight window under 1% also reads
        /// 0 — the reset date is what tells the two apart.
        case missingResetDate
    }
    var isBounded: Bool { limit != nil }

    /// Whether the row's value is a Used/Left reading a click can flip: a bounded reading with data, not
    /// a badge's text.
    var hasMeterStyleToggle: Bool {
        hasData && isBounded && valueTextOverride == nil
    }

    var displayedValue: Double {
        guard displayMode == .remaining, let limit else { return used }
        return max(0, limit - used)
    }

    /// Bar fill 0...1. Uses the same rounded value the row shows, so the bar and the number never
    /// disagree — a value that reads "0%" draws an empty bar instead of a tiny sliver.
    /// Display-mode-dependent: `remaining/limit` when the meter shows "remaining", `used/limit` when
    /// it shows "used". Use `remainingFraction` when the value must mean "remaining" regardless of
    /// display mode (e.g. quota notifications' under-10% check).
    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(roundedDisplayValue / limit, 0), 1)
    }

    /// Remaining share of the limit, 0...1, independent of the used/remaining display mode. Quota
    /// notifications use this for the "under 10% remaining" rule so the alert always reflects actual
    /// remaining, whether the row shows used or remaining.
    var remainingFraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max((limit - used) / limit, 0), 1)
    }

    /// Severity bands for the meter fill color (see `MeterState.severity`).
    enum MeterSeverity: Hashable {
        case normal, warning, critical
    }

    /// The meter's state (`meterState(now:)`): one reading for the bar's colour, the value's colour,
    /// the flame and the notifications, so none can contradict another. Precedence, highest first:
    /// no data → spent → the live pace verdict → the level bands.
    enum MeterState: Hashable {
        /// No real metric backs the row — gray, empty track.
        case noData
        /// Spent to nothing the user can see: a real zero, or a remainder so small it rounds to
        /// "0" at the value's precision ("0%", "$0.00", "0 credits"). Red, no flame: the bar is empty
        /// already. Outranks the pace verdict — a visibly empty bar is never a calmer colour.
        case spent
        /// Projected to run out before the reset, or to land right at the limit with no cushion to
        /// speak of. Red, with the flame.
        case runningOut
        /// Projected to land inside the last 10% — cutting it close — but still with a cushion of at
        /// least 1%. (A cushion that rounds to 0% promotes to `runningOut` instead.) Orange.
        case closeToLimit
        /// On course to finish with ≥10% to spare. Blue.
        case healthy
        /// No trustworthy projection — no reset window, a session not started, or too little used to
        /// extrapolate from: blue, orange once 75% of the limit is used (a quarter left), red once 90%
        /// is (a tenth left).
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
    }

    /// `displayedValue` rounded the same way `format(_:)` rounds it for the row's value.
    private var roundedDisplayValue: Double {
        roundedAtDisplayPrecision(displayedValue)
    }

    /// Rounds a value to the precision this kind shows in its value — whole percent, one-decimal
    /// count, or cents — so the meter geometry and the spent check never disagree with the printed
    /// number. (A value that reads "0%" must register as zero, not a hairline sliver.)
    private func roundedAtDisplayPrecision(_ value: Double) -> Double {
        switch kind {
        case .percent: return value.rounded()
        case .count: return (value * 10).rounded() / 10
        case .dollars: return (value * 100).rounded() / 100
        }
    }

    /// Primary value string for the menu bar and unbounded rows. Returns the no-data
    /// marker when no real metric backs the row, so no surface can print the descriptor's placeholder
    /// sample numbers as if they were measured usage.
    var valueText: String {
        guard hasData else { return Self.noDataValue }
        if let valueTextOverride { return valueTextOverride }
        // A `.values` row's primary reading is its first value; meters fall through to the
        // bounded/`used` formatting.
        if let first = values.first {
            return MetricFormatter.number(first.number, kind: first.kind, style: .row)
        }
        return format(displayedValue)
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
        if let first = values.first {
            if let traySuffix, first.kind == .count {
                return "\(MetricFormatter.number(first.number, kind: .count, style: .tray)) \(traySuffix)"
            }
            return MetricFormatter.string(for: first, style: .tray)
        }
        if let valueTextOverride { return valueTextOverride }
        return MetricFormatter.number(displayedValue, kind: kind, style: .tray)
    }

    /// Right-aligned descriptive line for an unbounded row (no bar): just "<value> <word>". The word is
    /// `unboundedValueWord` when set (extras always read "1,503 left", spend rows "$12.34 spent");
    /// otherwise it falls back to the global left/used mode word.
    var unboundedDetail: String {
        guard hasData else { return Self.noDataDetail }
        if let valueTextOverride { return valueTextOverride }
        if !values.isEmpty {
            // One value: a lone dollar amount takes the widget's trailing word ("$4.08 spent",
            // "$1,503 left"); any other single value carries its own unit label ("1.2M tokens",
            // "2 available"). Several values join into the combined reading ("$4.08 · 1.2M tokens").
            if values.count == 1 {
                let value = values[0]
                if value.kind == .dollars, let word = unboundedValueWord {
                    return "\(MetricFormatter.number(value.number, kind: .dollars, style: .row)) \(word)"
                }
                return MetricFormatter.string(for: value, style: .row)
            }
            return values.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · ")
        }
        return "\(valueText) \(unboundedValueWord ?? displayMode.label.lowercased())"
    }

    /// Color bands for reset-credit expiries: blue normally, orange under a week, red under 48 hours.
    /// A past-due expiry remains critical until the next refresh drops it from the available list.
    static let expiryWarningWindow: TimeInterval = 7 * 24 * 60 * 60
    static let expiryCriticalWindow: TimeInterval = 48 * 60 * 60

    /// Severity band for a single expiry `timeRemaining` seconds out: red under 48h, orange under a
    /// week, blue beyond, for the resets popover's per-credit dots.
    static func expirySeverity(secondsRemaining: TimeInterval) -> MeterSeverity {
        if secondsRemaining <= expiryCriticalWindow { return .critical }
        if secondsRemaining <= expiryWarningWindow { return .warning }
        return .normal
    }

    /// The available reset-credit count backing a `showsResetExpiries` row (its "N available" figure).
    /// Lets the popover tell "no credits" (empty state) from "credits whose per-credit expiries we
    /// couldn't fetch" — the usage-body fallback carries the count but no expiry list, so `expiriesAt`
    /// is empty while the row still reads e.g. "3 available".
    var resetCreditCount: Int {
        Int((values.first?.number ?? 0).rounded(.down))
    }

    /// Bounded/fallback formatting in the popover row's compact style, so a meter's value always fits
    /// the dashboard's value column at full size. Unbounded `.values` rows format their values directly
    /// (`unboundedDetail`).
    private func format(_ value: Double) -> String {
        MetricFormatter.number(value, kind: kind, style: .row)
    }
}

// MARK: - Meter state

extension WidgetData {
    /// The inputs pacing needs, present only for a bounded metric with a known reset window. `nil`
    /// short-circuits the live pace verdict (e.g. unbounded rows, no-data rows, rows whose
    /// reset/period cadence is unknown).
    private var paceContext: (limit: Double, resetsAt: Date, period: TimeInterval)? {
        guard hasData, let limit, limit > 0, let resetsAt,
              let periodDurationMs, periodDurationMs > 0 else { return nil }
        return (limit, resetsAt, TimeInterval(periodDurationMs) / 1000)
    }

    /// The meter's state at `now`, the one source the bar's and the value's colour, the flame and the
    /// notifications read. Precedence, highest first:
    ///
    /// 1. **No data** → gray, empty.
    /// 2. **Spent** → red, whenever the remainder rounds to zero at the value's precision (a visibly
    ///    empty bar always reads spent, pace aside).
    /// 3. **Live pace verdict** (a reset window): blue `healthy` while ≥10% is projected to spare,
    ///    orange `closeToLimit` when projected inside the last 10% *with a cushion of at least 1%*,
    ///    red `runningOut` when projected to blow past the limit before the reset or to land right at
    ///    it (cushion rounds to 0%).
    /// 4. **Level bands** (no window to project against, a session not started, or so little used
    ///    that a linear projection is noise) → orange once 75% of the limit is used (a quarter left),
    ///    red once 90% is (a tenth left), blue below, rounded to the whole percent the value shows.
    ///
    /// Every band keys off the share *used*, never the displayed fraction, so the colour doesn't flip
    /// with the Used/Left toggle.
    func meterState(now: Date = Date()) -> MeterState {
        guard hasData, let limit, limit > 0 else { return hasData ? .level(.normal) : .noData }
        if roundedAtDisplayPrecision(limit - used) <= 0 { return .spent }
        guard let pace = pace(now: now) else { return levelState(used: used, limit: limit) }
        switch pace.status {
        case .ahead:
            return .healthy
        case .onTrack:
            let spare = Int(((1 - pace.projectedFraction) * 100).rounded())
            return spare >= 1 ? .closeToLimit : .runningOut
        case .behind:
            return .runningOut
        }
    }

    /// The bar's hover on the live dashboard: where the pace lands at reset, the one figure the row
    /// doesn't show. Blue → the cushion ("~35% left at reset"); orange → the projected usage ("~92% used
    /// at reset", "~100%" when it lands right at the limit); red → the overage ("~12% over limit at
    /// reset"); "Limit reached" once spent. `nil` where there is no pace story: no data, or a level band.
    func paceTooltip(now: Date = Date()) -> String? {
        if meterState(now: now) == .spent { return "Limit reached" }
        guard let pace = pace(now: now) else { return nil }
        let percent = { (share: Double) in Int((share * 100).rounded()) }
        switch pace.status {
        case .ahead: return "~\(percent(1 - pace.projectedFraction))% left at reset"
        case .onTrack: return "~\(percent(pace.projectedFraction))% used at reset"
        // Floored to 1% so a bar projected even slightly over never reads "~0% over limit".
        case .behind: return "~\(max(1, percent(pace.projectedFraction - 1)))% over limit at reset"
        }
    }

    /// The live pace verdict and where it lands at reset as a share of the limit (1 is right at it), or
    /// `nil` where there is no trustworthy projection: no reset window, a session window nothing has
    /// been spent in, or so little used that a linear projection is noise. Coarse whole-percent meters
    /// can read 1% used very early in a window, and linear extrapolation then projects a bogus blow-out
    /// while the value still shows ~99% left: when >95% of the quota clearly remains (used below 5%),
    /// only a comfortable projection is trusted.
    private func pace(now: Date) -> (status: Pace.Status, projectedFraction: Double)? {
        guard !isFreshSessionWindow(now: now), let ctx = paceContext,
              let result = Pace.evaluate(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                         periodDuration: ctx.period, now: now)
        else { return nil }
        guard result.status == .ahead || used / ctx.limit >= 0.05 else { return nil }
        return (result.status, result.projectedUsage / ctx.limit)
    }

    /// The colour band for the share used, where there is no trustworthy pace projection: orange at
    /// 75% used, red at 90%, blue below.
    private func levelState(used: Double, limit: Double) -> MeterState {
        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 75 { return .level(.warning) }
        return .level(.normal)
    }

    /// Session meters only (Claude/Antigravity/OpenCode): a "not started" state for the current window
    /// when nothing has been spent in it yet, detected through the descriptor's `sessionStartSignal`
    /// (see `SessionStartSignal` for why each provider trusts its signal). Both signals read frozen
    /// snapshot fields, not a `resetsAt - now ≈ full period` window-timing test — that test is only
    /// valid the instant the snapshot is captured, then drifts every second until the next refresh,
    /// which split the value from its reset (a full bar beside a countdown that should be empty).
    /// `.zeroUsage` is additionally gated on `now < resetsAt`: once the reset has passed the snapshot
    /// is stale, so we drop the fresh-window claim and let the row fall back to the normal countdown.
    func isFreshSessionWindow(now: Date = Date()) -> Bool {
        guard let signal = sessionStartSignal, hasData, limit != nil, used <= 0 else { return false }
        switch signal {
        case .zeroUsage:
            guard let resetsAt else { return false }
            return now < resetsAt
        case .missingResetDate:
            return resetsAt == nil
        }
    }
}
