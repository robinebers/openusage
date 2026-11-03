import Foundation

/// What one history row shows. A row holds two figures at most, because a third overflows the value column.
enum HistoryRow: Hashable, Sendable {
    /// "Today  $1.20 · 1.2M tokens"
    case window(UsageWindow, UsageMeasure, then: UsageMeasure? = nil)
    /// "Usage Events  4.1K in 30 days"
    case measure(String, UsageMeasure, over: UsageWindow)

    var title: String {
        switch self {
        case .window(let window, _, _): window.title
        case .measure(let title, _, _): title
        }
    }

    var window: UsageWindow {
        switch self {
        case .window(let window, _, _), .measure(_, _, let window): window
        }
    }

    private var measures: [UsageMeasure] {
        switch self {
        case .window(_, let first, let then): [first, then].compactMap { $0 }
        case .measure(_, let measure, _): [measure]
        }
    }

    private func value(_ measure: UsageMeasure, _ number: Double) -> MetricValue {
        guard case .measure(_, _, let window) = self else { return measure.metricValue(number) }
        return MetricValue(number: number, kind: measure.metricValue(number).kind, label: window.phrase)
    }

    /// Nil when none of the row's figures was reported.
    func line(label: String, in history: UsageHistory) -> MetricLine? {
        guard let totals = history.totals(over: window) else { return nil }
        let values = measures.compactMap { measure in totals[measure].map { value(measure, $0) } }
        return values.isEmpty ? nil : .values(label: label, values: values)
    }

    /// The row's own figures out of a saved line, which an earlier build may have written with others, such as BYOK.
    func figures(in values: [MetricValue]) -> [MetricValue] {
        values.filter { saved in measures.contains { value($0, saved.number) == saved } }
    }

    /// The window rows' hover detail; a measure row has none.
    func breakdown(in history: UsageHistory) -> UsageBreakdown? {
        guard case .window(let window, _, _) = self else { return nil }
        return UsageBreakdown(window, in: history)
    }

    static func append(to snapshot: inout ProviderSnapshot, for descriptors: [WidgetDescriptor], in history: UsageHistory?) {
        guard let history else { return }
        var breakdowns: [String: UsageBreakdown] = [:]
        for descriptor in descriptors {
            guard let row = descriptor.historyRow, let line = row.line(label: descriptor.metricLabel, in: history) else { continue }
            snapshot.lines.append(line)
            breakdowns[descriptor.key] = row.breakdown(in: history)
        }
        snapshot.usageBreakdowns = breakdowns.isEmpty ? nil : breakdowns
    }

    /// How many days back from today the descriptors' rows reach, so a source reads exactly those.
    static func dayCount(for descriptors: [WidgetDescriptor]) -> Int? {
        descriptors.compactMap { $0.historyRow?.window.dayOffsets?.upperBound }.max().map { $0 + 1 }
    }
}

extension WidgetDescriptor {
    static func history(key: String, provider: Provider, _ row: HistoryRow) -> WidgetDescriptor {
        var descriptor = values(key: key, provider: provider, title: row.title)
        descriptor.historyRow = row
        return descriptor
    }
}
