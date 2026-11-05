import Foundation

struct DashboardRowModel: Equatable {
    enum Mark: Equatable {
        case bar(fill: Double, severity: WidgetData.MeterSeverity, value: String, reset: String?, isUsedUp: Bool = false)
        case value(String, detail: String? = nil, severity: WidgetData.MeterSeverity = .normal)
    }

    let label: String
    let mark: Mark
    /// Clock times run wider than countdowns, so they get the wider reset lane.
    var showsClockTimes = false
    /// Where the bar would reach by now at an even pace, or nil when it has no mark.
    var paceMark: Double?

    /// A limit that's used up with nothing left to draw. Under Used its bar is full and stays at full strength.
    var isFaded: Bool {
        guard case .bar(let fill, _, _, _, let isUsedUp) = mark else { return false }
        return isUsedUp && fill == 0
    }
}

extension WidgetData {
    func dashboardRow(now: Date = Date()) -> DashboardRowModel {
        guard hasData, isBounded else {
            let figures = unboundedFigures
            let detail = figures.count > 1 ? figures.dropFirst().joined(separator: " · ") : nil
            return DashboardRowModel(label: title, mark: .value(figures[0], detail: detail, severity: expirySeverity(now: now)))
        }
        return DashboardRowModel(
            label: title,
            mark: .bar(
                fill: fraction,
                severity: severity,
                value: valueText,
                reset: compactResetText(now: now),
                isUsedUp: meterState(now: now) == .spent
            ),
            showsClockTimes: resetDisplayMode == .absolute,
            paceMark: paceMark(now: now)
        )
    }

    /// The reading with the word that explains it, like `49% left`.
    var amountText: String {
        hasMeterStyleToggle ? "\(valueText) \(displayMode.label.lowercased())" : valueText
    }

    func compactResetText(now: Date = Date()) -> String? {
        guard hasData, let resetsAt, !isFreshSessionWindow(now: now) else { return nil }
        guard resetsAt.timeIntervalSince(now) > 0 else { return Formatters.imminent }
        return Self.resetReading(resetsAt, as: resetDisplayMode, now: now)
    }

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

    var meterStyleTooltip: String? {
        guard hasMeterStyleToggle, let limit else { return nil }
        let other = displayMode == .remaining ? used : max(0, limit - used)
        let word = (displayMode == .remaining ? WidgetDisplayMode.used : .remaining).label.lowercased()
        return "\(MetricFormatter.number(other, kind: kind, style: .row, currencyCode: currencyCode)) \(word)"
    }
}
