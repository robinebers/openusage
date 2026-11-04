import Foundation

extension WidgetDescriptor {
    static func percent(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        sessionStartSignal: WidgetData.SessionStartSignal? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, kind: .percent, used: 0, limit: 100)
        sample.sessionStartSignal = sessionStartSignal
        return WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel ?? title, sample: sample)
    }

    static func boundedDollars(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel ?? title,
                         sample: WidgetData(title: title, kind: .dollars, used: 0, limit: limit, unboundedValueWord: valueWord))
    }

    static func boundedCount(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel ?? title,
                         sample: WidgetData(title: title, kind: .count, used: 0, limit: limit,
                                                            periodDurationMs: periodDurationMs))
    }

    static func values(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String? = nil,
        showsResetExpiries: Bool = false
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, kind: .dollars, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.showsResetExpiries = showsResetExpiries
        return WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel ?? title, sample: sample)
    }

    static func badge(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel ?? title,
                         sample: WidgetData(title: title, kind: .count, used: 0, limit: nil))
    }
}
