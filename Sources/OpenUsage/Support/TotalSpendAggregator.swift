import Foundation

/// The spend period the Total Spend card can show — matching the three per-provider spend tiles
/// `SpendTileMapper` emits, whose line labels double as the lookup keys here.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// The metric-line label this period sums across providers (identical to the raw value today,
    /// but kept as its own accessor so the two meanings can diverge without a hunt).
    var lineLabel: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// Which quantity the Total Spend card's ring, center, and legend show. The title menu persists this
/// choice; the aggregator always collects both dollars and tokens so flipping modes doesn't re-scan.
/// Raw value `apiSpend` is kept so existing installs don't lose their stored Cost selection.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    /// Menu order is declaration order: Cost → Cost/MTok → Tokens. Cost is the default.
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    /// Empty-state copy when no provider qualifies for this metric in the selected period.
    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    /// Dollar-backed modes can inherit the local-estimate note when any contributor's spend is imputed.
    var usesDollarEstimateNote: Bool {
        switch self {
        case .cost, .costPerMtok: true
        case .tokens: false
        }
    }
}

/// One provider's contribution to a period's total: dollars and tokens from the same spend line,
/// plus whether the dollars are a local estimate (log-scanned providers) or measured (Cursor's CSV).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool

    var id: String { provider.id }

    /// Dollars per million tokens for this provider alone. `nil` when either side is missing.
    var costPerMtok: Double? {
        guard amountUSD > 0, tokenCount > 0 else { return nil }
        return (amountUSD / tokenCount) * 1_000_000
    }
}

/// One provider's ready-to-draw contribution under a chosen metric: the amount that sizes the ring
/// and ranks the legend, plus the formatted value surfaces read through `MetricFormatter`.
struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let provider: Provider
    let displayAmount: Double
    let estimated: Bool

    var id: String { provider.id }
}

/// A period's cross-provider totals under one metric: ranked slices, center value, and estimate flag.
struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool

    var isEmpty: Bool { slices.isEmpty }
}

/// A period's cross-provider raw totals: every spend-capable provider that contributed dollars and/or
/// tokens. Presentation (include / rank / center) is `projection(for:)`.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// Raw storage empty — no provider had dollars or tokens for the period.
    var isEmpty: Bool { slices.isEmpty }

    /// Filters, ranks, and computes the center value for the title menu's selected metric.
    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost:
                guard slice.amountUSD > 0 else { return nil }
                return (slice, slice.amountUSD)
            case .tokens:
                guard slice.tokenCount > 0 else { return nil }
                return (slice, slice.tokenCount)
            case .costPerMtok:
                guard let rate = slice.costPerMtok else { return nil }
                return (slice, rate)
            }
        }

        let ranked = included.sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display > rhs.display }
            return lhs.slice.provider.displayName.localizedStandardCompare(rhs.slice.provider.displayName) == .orderedAscending
        }

        let projected = ranked.map {
            TotalSpendProjectedSlice(provider: $0.slice.provider, displayAmount: $0.display, estimated: $0.slice.estimated)
        }

        let center: Double
        let estimated: Bool
        switch metric {
        case .cost:
            center = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            estimated = ranked.contains { $0.slice.estimated }
        case .tokens:
            center = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            estimated = false
        case .costPerMtok:
            let usd = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            let tokens = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            center = tokens > 0 ? (usd / tokens) * 1_000_000 : 0
            estimated = ranked.contains { $0.slice.estimated }
        }

        return TotalSpendProjection(metric: metric, slices: projected, centerValue: center, isEstimated: estimated)
    }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// Total Spend ring card. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and
/// never fetches. A provider contributes when its snapshot carries a `.values` line with the period's
/// label *and* that line has dollars and/or tokens — idle periods (no line) are excluded, never zero.
enum TotalSpendAggregator {
    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices keep provider display order input only as a stable traversal; metric projection re-ranks.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot]
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  case .values(_, let values, _, _, _, _) = line else { return nil }

            let dollars = values.filter { $0.kind == .dollars }
            let amount = dollars.reduce(0) { $0 + $1.number }
            let tokens = values
                .filter { $0.kind == .count && $0.label == "tokens" }
                .reduce(0) { $0 + $1.number }
            guard amount > 0 || tokens > 0 else { return nil }

            return TotalSpendSlice(
                provider: provider,
                amountUSD: max(amount, 0),
                tokenCount: max(tokens, 0),
                estimated: dollars.contains(where: \.estimated)
            )
        }
        return TotalSpend(period: period, slices: slices)
    }
}
