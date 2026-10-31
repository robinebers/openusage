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

    /// Nil when none of the row's figures was reported for every day it covers.
    func line(label: String, in history: UsageHistory) -> MetricLine? {
        guard let totals = history.totals(over: window) else { return nil }
        let values: [MetricValue] = switch self {
        case .window(_, let first, let then):
            [first, then].compactMap { $0 }.compactMap { measure in totals[measure].map(measure.metricValue) }
        case .measure(_, let measure, let window):
            totals[measure].map { [MetricValue(number: $0, kind: measure.metricValue($0).kind, label: window.phrase)] } ?? []
        }
        return values.isEmpty ? nil : .values(label: label, values: values)
    }

    /// The window rows' hover detail; a measure row has none.
    func breakdown(in history: UsageHistory) -> UsageBreakdown? {
        guard case .window(let window, _, _) = self else { return nil }
        return UsageBreakdown(window, in: history)
    }

    static func lines(for descriptors: [WidgetDescriptor], in history: UsageHistory?) -> [MetricLine] {
        guard let history else { return [] }
        return descriptors.compactMap { descriptor in
            descriptor.historyRow?.line(label: descriptor.metricLabel, in: history)
        }
    }

    /// How many days back from today the descriptors' rows reach, so a source reads exactly those.
    static func dayCount(for descriptors: [WidgetDescriptor]) -> Int? {
        descriptors.compactMap { $0.historyRow?.window.dayOffsets.upperBound }.max().map { $0 + 1 }
    }
}

extension WidgetDescriptor {
    static func history(key: String, provider: Provider, _ row: HistoryRow) -> WidgetDescriptor {
        var descriptor = values(key: key, provider: provider, title: row.title)
        descriptor.historyRow = row
        return descriptor
    }
}
