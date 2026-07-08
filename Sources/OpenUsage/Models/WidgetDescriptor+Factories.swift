import Foundation

/// Shared descriptor factories — the one place that knows how a descriptor's sample `WidgetData`
/// is assembled, so a provider declares its gallery as a flat list instead of re-implementing the
/// same private builders. Sample numbers are structural only (a row without real data renders the
/// no-data marker, never the sample), so every factory seeds `used: 0`.
extension WidgetDescriptor {
    /// Bounded 0–100% meter (session/weekly-style quotas). `isSessionWindow` opts the tile into the
    /// "Not started" fresh-window treatment (rolling 5-hour session pools), replacing a hardcoded
    /// widget-ID list in the model.
    static func percent(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        isSessionWindow: Bool = false
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        sample.isSessionWindow = isSessionWindow
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Bounded dollar meter whose subtitle reads "$<limit> <limitNoun>" (noun defaults to "limit").
    /// `valueWord` is the trailing word for the *uncapped* fallback: a tile like Claude's Extra Usage is a
    /// meter when the provider reports a monthly cap (`.progress`) but an unbounded "$1.2K spent" row
    /// (`.values`) when it doesn't, and that row needs a word. It's inert for the bounded rendering.
    static func boundedDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        limitNoun: String? = nil,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: limit, limitNoun: limitNoun,
                                unboundedValueWord: valueWord))
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
        valueWord: String? = nil,
        isUsagePeriod: Bool = false,
        traySuffix: String? = nil,
        showsResetExpiries: Bool = false
    ) -> WidgetDescriptor {
        // `kind` is unused for `.values` rendering (each value carries its own), but a count-only tile
        // reads tidier seeded as `.count`; everything else defaults to `.dollars`.
        let kind: MetricKind = { if case .kind(let only) = selection { return only }; return .dollars }()
        var sample = WidgetData(title: title, icon: provider.icon, kind: kind, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.selection = selection
        sample.isUsagePeriod = isUsagePeriod
        sample.traySuffix = traySuffix
        sample.showsResetExpiries = showsResetExpiries
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Combined tile reading "$4.08 · 1.2M tokens" (spend) or "$32.84 · 821 credits" (Codex credits) —
    /// every value of a `.values` row, joined.
    static func combined(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        isUsagePeriod: Bool = false
    ) -> WidgetDescriptor {
        values(id: id, provider: provider, title: title, metricLabel: metricLabel, selection: .all,
               isUsagePeriod: isUsagePeriod)
    }

    /// The three local-spend tiles every spend-tracking provider exposes — Today / Yesterday / Last 30
    /// Days — each a combined "cost · tokens" row, backed by `SpendTileMapper`. Ids are
    /// `<provider>.today|yesterday|last30`, so the set is identical across Claude / Codex / Cursor / Grok.
    static func spendTiles(provider: Provider) -> [WidgetDescriptor] {
        var descriptors: [WidgetDescriptor] = [
            .combined(id: "\(provider.id).today", provider: provider, title: "Today", isUsagePeriod: true),
            .combined(id: "\(provider.id).yesterday", provider: provider, title: "Yesterday", isUsagePeriod: true),
            .combined(id: "\(provider.id).last30", provider: provider, title: "Last 30 Days", isUsagePeriod: true)
        ]
        if provider.id == "cursor" {
            descriptors = descriptors.map { descriptor in
                var sample = descriptor.sample
                sample.valueTooltipNote = WidgetData.cursorUsageHistoryNote
                return WidgetDescriptor(
                    id: descriptor.id,
                    providerID: descriptor.providerID,
                    metricLabel: descriptor.metricLabel,
                    sample: sample,
                    pinnable: descriptor.pinnable
                )
            }
        }
        // Mark the whole set as the local spend tiles — the Total Spend card's capability and
        // contribution signal.
        return descriptors.map { descriptor in
            var marked = descriptor
            marked.isSpendTile = true
            return marked
        }
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

    /// The Usage Trend row: a day-by-day token sparkline backed by a provider `.chart` line. Not
    /// pinnable — the tray can't draw a chart — but otherwise a normal Customize widget (toggle,
    /// reorder, hide). The sample carries a few bars so it reads as a chart in the gallery.
    static func usageTrend(provider: Provider) -> WidgetDescriptor {
        var sample = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        sample.isChart = true
        sample.chartPoints = sampleTrendPoints
        return make(id: "\(provider.id).trend", provider: provider, metricLabel: "Usage Trend",
                    sample: sample, pinnable: false)
    }

    /// A gentle wave of sample bars so the gallery preview reads as a trend chart, never confused for
    /// real usage (the dashboard renders real points or "No data", never this sample).
    private static let sampleTrendPoints: [MetricChartPoint] = [
        9, 14, 11, 22, 13, 18, 25, 16, 12, 28, 20, 15, 31, 19, 24
    ].enumerated().map { MetricChartPoint(value: Double($0.element), label: "\($0.offset)") }

    private static func make(
        id: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData,
        pinnable: Bool = true
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: sample,
            pinnable: pinnable
        )
    }
}
