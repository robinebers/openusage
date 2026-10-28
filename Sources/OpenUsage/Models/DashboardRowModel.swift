import Foundation

struct DashboardRowModel: Equatable {
    enum Mark: Equatable {
        case bar(fill: Double, severity: WidgetData.MeterSeverity, value: String, reset: String?, flame: Bool = false)
        case value(String, severity: WidgetData.MeterSeverity? = nil)
    }

    let label: String
    let mark: Mark
}

extension WidgetData {
    func dashboardRow(now: Date = Date()) -> DashboardRowModel {
        guard hasData, isBounded else {
            return DashboardRowModel(label: title, mark: .value(unboundedDetail, severity: expirySeverity(now: now)))
        }
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
        return "\(MetricFormatter.number(other, kind: kind, style: .row)) \(word)"
    }
}
