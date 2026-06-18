import Foundation

/// Shared descriptor factories — the one place that knows how a descriptor's sample `WidgetData`
/// is assembled, so a provider declares its gallery as a flat list instead of re-implementing the
/// same private builders. Sample numbers are structural only (a row without real data renders the
/// no-data marker, never the sample), so every factory seeds `used: 0`.
extension WidgetDescriptor {
    /// Bounded 0–100% meter (session/weekly-style quotas).
    static func percent(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .percent, used: 0, limit: 100))
    }

    /// Bounded dollar meter whose subtitle reads "$<limit> <limitNoun>" (noun defaults to "limit").
    static func boundedDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        limitNoun: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: limit, limitNoun: limitNoun))
    }

    /// Bounded count meter (e.g. requests per billing cycle). `periodDurationMs` lets the subtitle
    /// show the cycle's reset cadence instead of the bare suffix.
    static func boundedCount(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        suffix: String,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: limit, countSuffix: suffix,
                                periodDurationMs: periodDurationMs))
    }

    /// Unbounded numeric row backed by a provider `.values` line. `selection` decides which of the
    /// row's values this tile renders (cost-only, tokens-only, or the combined `.all`); `valueWord` is
    /// the trailing word for a lone dollar value ("spent", "left"). The ⓘ for a locally-estimated
    /// dollar amount is data-driven (set when a shown value is `estimated`), so it isn't a parameter.
    static func values(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        selection: ValueSelection = .all,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        // `kind` is unused for `.values` rendering (each value carries its own), but a count-only tile
        // reads tidier seeded as `.count`; everything else defaults to `.dollars`.
        let kind: MetricKind = { if case .kind(let only) = selection { return only }; return .dollars }()
        var sample = WidgetData(title: title, icon: provider.icon, kind: kind, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.selection = selection
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Combined tile reading "$4.08 · 1.2M tokens" (spend) or "$32.84 · 821 credits" (Codex credits) —
    /// every value of a `.values` row, joined.
    static func combined(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        values(id: id, provider: provider, title: title, metricLabel: metricLabel, selection: .all)
    }

    /// The three local-spend tiles every spend-tracking provider exposes — Today / Yesterday / Last 30
    /// Days — each a combined "cost · tokens" row, backed by `SpendTileMapper`. Ids are
    /// `<provider>.today|yesterday|last30`, so the set is identical across Claude / Codex / Cursor / Grok.
    static func spendTiles(provider: Provider) -> [WidgetDescriptor] {
        [
            .combined(id: "\(provider.id).today", provider: provider, title: "Today"),
            .combined(id: "\(provider.id).yesterday", provider: provider, title: "Yesterday"),
            .combined(id: "\(provider.id).last30", provider: provider, title: "Last 30 Days")
        ]
    }

    /// Unbounded dollar balance with a custom trailing word (e.g. "$1,503.00 left").
    static func dollarBalance(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil, unboundedValueWord: valueWord))
    }

    /// Unbounded count resolved from a provider `.badge` line via `valueTextOverride`
    /// (e.g. Grok pay-as-you-go).
    static func badge(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: nil))
    }

    private static func make(
        id: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: sample
        )
    }
}
