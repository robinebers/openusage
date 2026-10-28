import Foundation

/// Shared descriptor factories — the one place that knows how a descriptor's template `WidgetData`
/// is assembled, so providers declare flat metric lists instead of re-implementing the same private
/// builders. Template numbers are structural only (a row without real data renders the no-data marker,
/// never the template), so every factory seeds `used: 0`.
extension WidgetDescriptor {
    /// Bounded 0–100% meter (session/weekly-style quotas). `sessionStartSignal` opts the tile into the
    /// fresh-window treatment (rolling 5-hour session pools: a full bar and no reset until something is
    /// spent) and names how that state is detected for this provider — see `WidgetData.SessionStartSignal`.
    static func percent(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        sessionStartSignal: WidgetData.SessionStartSignal? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, kind: .percent, used: 0, limit: 100)
        sample.sessionStartSignal = sessionStartSignal
        return make(key: key, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Bounded dollar meter. `valueWord` is the trailing word for the *uncapped* fallback: a tile like Claude's Extra Usage is a
    /// meter when the provider reports a monthly cap (`.progress`) but an unbounded "$1.2K spent" row
    /// (`.values`) when it doesn't, and that row needs a word. It's inert for the bounded rendering.
    static func boundedDollars(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        make(key: key, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, kind: .dollars, used: 0, limit: limit, unboundedValueWord: valueWord))
    }

    /// Bounded count meter (e.g. requests per billing cycle). `periodDurationMs` is the cycle the pace
    /// verdict projects against.
    static func boundedCount(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        make(key: key, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, kind: .count, used: 0, limit: limit,
                                periodDurationMs: periodDurationMs))
    }

    /// Unbounded numeric row backed by a provider `.values` line; every value in the line is shown.
    static func values(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String? = nil,
        traySuffix: String? = nil,
        showsResetExpiries: Bool = false
    ) -> WidgetDescriptor {
        // `kind` is unused for `.values` rendering (each value carries its own).
        var sample = WidgetData(title: title, kind: .dollars, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.traySuffix = traySuffix
        sample.showsResetExpiries = showsResetExpiries
        return make(key: key, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Unbounded dollar balance with a custom trailing word (e.g. "$1,503.00 left").
    static func dollarBalance(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String
    ) -> WidgetDescriptor {
        make(key: key, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, kind: .dollars, used: 0, limit: nil, unboundedValueWord: valueWord))
    }

    /// Unbounded count resolved from a provider `.badge` line via `valueTextOverride`
    /// (e.g. Grok pay-as-you-go).
    static func badge(
        key: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(key: key, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, kind: .count, used: 0, limit: nil))
    }

    private static func make(
        key: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData
    ) -> WidgetDescriptor {
        WidgetDescriptor(provider: provider, key: key, metricLabel: metricLabel, sample: sample)
    }
}
