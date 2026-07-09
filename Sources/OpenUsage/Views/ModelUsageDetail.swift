import SwiftUI

/// Hover detail for a spend period: a flat ranked list of models, each two text lines (name/cost,
/// share percent/tokens) over a proportional share bar. Rows carry no tooltips — everything shown is
/// already on the row. The header carries only the period name — the hovered row right below already
/// shows the period total, so repeating it here would duplicate (and wrap on) long figures. Mirrors
/// `UsageTrendDetail`'s calm — header + flat list + source note.
struct ModelUsageDetail: View {
    let title: String
    let breakdown: ModelUsageBreakdown
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let width: CGFloat = 280

    var body: some View {
        let shares = Self.shares(for: breakdown.models)
        let percents = Self.wholePercents(shares)
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(breakdown.models.indices, id: \.self) { index in
                    modelRow(breakdown.models[index], share: shares[index], percent: percents[index])
                }
            }
            PopoverSourceNote(text: breakdown.sourceNote)
        }
        .padding(14)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: density.headerPointSize, weight: .semibold))
            .foregroundStyle(.primary)
    }

    /// Two text lines and the bar: model name / cost on top, share percent / tokens beneath. The name
    /// only competes with the short cost figure, so it almost never truncates; the percent line answers
    /// what the bar can't say precisely.
    private func modelRow(_ model: ModelUsageEntry, share: Double, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.model)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let cost = model.costUSD {
                    Text(MetricFormatter.number(cost, kind: .dollars, style: .row))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: density.supportingPointSize))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percent)%")
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MetricFormatter.string(
                    for: MetricValue(number: Double(model.totalTokens), kind: .count, label: "tokens"),
                    style: .row
                ))
                .monospacedDigit()
            }
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.meterFill(.normal))
                            .frame(width: proxy.size.width * share)
                    }
            }
            .frame(height: density.meterHeight)
            .padding(.top, 2)
        }
        .padding(.vertical, density.textRowPadding)
    }

    /// Share against the sum of the listed models' own (display-rounded) figures, not the spend row's
    /// `totalCostUSD` — that total is rounded per day on a different path, so using it would let the
    /// percentages drift from the numbers printed right next to them.
    ///
    /// One basis for the whole list: cost shares only when every listed model is priced — otherwise a
    /// column mixing cost shares (priced rows) with token shares (unpriced rows) would sum past 100%.
    /// With any unpriced model present, every row falls back to its token share.
    static func shares(for models: [ModelUsageEntry]) -> [Double] {
        let allPriced = models.allSatisfy { $0.costUSD != nil }
        if allPriced {
            let costTotal = models.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
            if costTotal > 0 {
                return models.map { model in
                    min(max((model.costUSD ?? 0) / costTotal, 0), 1)
                }
            }
        }
        let tokenTotal = models.reduce(0) { $0 + $1.totalTokens }
        guard tokenTotal > 0 else { return models.map { _ in 0 } }
        return models.map { model in
            min(max(Double(model.totalTokens) / Double(tokenTotal), 0), 1)
        }
    }

    /// Integer percentages that always total exactly 100 (largest-remainder rounding): rounding each
    /// share independently can print a column that sums to 99 or 101, so every share is floored and
    /// the leftover points go to the rows with the biggest fractional remainders. All-zero shares
    /// (an empty period) stay all zero.
    static func wholePercents(_ shares: [Double]) -> [Int] {
        guard shares.contains(where: { $0 > 0 }) else { return shares.map { _ in 0 } }
        let raw = shares.map { $0 * 100 }
        var percents = raw.map { Int($0.rounded(.down)) }
        var leftover = 100 - percents.reduce(0, +)
        guard leftover > 0 else { return percents }
        let byRemainder = raw.indices.sorted {
            let lhs = raw[$0] - raw[$0].rounded(.down)
            let rhs = raw[$1] - raw[$1].rounded(.down)
            if lhs != rhs { return lhs > rhs }
            return $0 < $1
        }
        for index in byRemainder where leftover > 0 {
            percents[index] += 1
            leftover -= 1
        }
        return percents
    }
}
