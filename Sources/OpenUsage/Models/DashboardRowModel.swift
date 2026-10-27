import Foundation

/// One metric as the dashboard draws it, resolved from a `WidgetData` for one instant so the bar's colour,
/// the value, the flame and the reset can never disagree. A reading with a limit is a capacity bar filled
/// with what is left (or what is used, under the Used setting) in its state's colour
/// (`WidgetData.meterState`), its value and its reset beside it, and a flame before the value while it
/// is projected to run out; a reading without one shows its value in the bar's place.
struct DashboardRowModel: Equatable {
    enum Mark: Equatable {
        /// A capacity bar: `fill` is the share shown (0...1), tinted by `severity`; `value` is "64%",
        /// "$12", "320"; `reset` is the countdown or clock time, `nil` without a live reset; `flame` is
        /// on while the reading is projected to run out before the reset, the one red state that isn't
        /// spent yet — never on a blue or an orange bar.
        case bar(fill: Double, severity: WidgetData.MeterSeverity, value: String, reset: String?, flame: Bool = false)
        /// A reading with no limit: its value, where the bar would start.
        case value(String)
    }

    let label: String
    let mark: Mark
}

extension WidgetData {
    /// The row for this reading at `now`.
    func dashboardRow(now: Date = Date()) -> DashboardRowModel {
        guard hasData, isBounded else { return DashboardRowModel(label: title, mark: .value(unboundedDetail)) }
        let state = meterState(now: now)
        return DashboardRowModel(
            label: title,
            mark: .bar(
                fill: fraction,
                severity: state.severity ?? .normal,
                value: valueText,
                reset: compactResetText(now: now),
                flame: state == .runningOut
            )
        )
    }

    /// The reset column's reading: "1h 40m" as a countdown, or "5:30 PM" / "Wed 4 PM" as a clock time
    /// under that setting; "soon" once the reset is due. `nil` when the row has no live reset: no reset
    /// date, or a session window that has not started.
    func compactResetText(now: Date = Date()) -> String? {
        guard hasData, let resetsAt, !isFreshSessionWindow(now: now) else { return nil }
        guard resetsAt.timeIntervalSince(now) > 0 else { return Formatters.imminent }
        return Self.resetReading(resetsAt, as: resetDisplayMode, now: now)
    }

    /// The reset's hover on the live dashboard: the other format, the clock time under a countdown and
    /// the countdown under a clock time. `nil` when the row has no live reset, or the reset is due and
    /// reads "soon" either way.
    func resetTooltip(now: Date = Date()) -> String? {
        guard hasData, let resetsAt, !isFreshSessionWindow(now: now), resetsAt.timeIntervalSince(now) > 0 else { return nil }
        return Self.resetReading(resetsAt, as: resetDisplayMode == .relative ? .absolute : .relative, now: now)
    }

    private static func resetReading(_ resetsAt: Date, as mode: ResetDisplayMode, now: Date) -> String? {
        switch mode {
        case .relative: Formatters.compactDuration(resetsAt.timeIntervalSince(now))
        case .absolute: Formatters.compactClock(resetsAt, now: now)
        }
    }

    /// The value's hover on the live dashboard: the other reading, what is used under Left and what is
    /// left under Used ("36% used" beside "64%"). `nil` where the value isn't a Used/Left reading.
    var meterStyleTooltip: String? {
        guard hasMeterStyleToggle, let limit else { return nil }
        let other = displayMode == .remaining ? used : max(0, limit - used)
        let word = (displayMode == .remaining ? WidgetDisplayMode.used : .remaining).label.lowercased()
        return "\(MetricFormatter.number(other, kind: kind, style: .row)) \(word)"
    }
}
