import SwiftUI

/// The Usage Trend row: a compact, right-aligned day-by-day token sparkline that reads at a glance and
/// keeps the card's row rhythm. Hovering reveals a larger, readable chart (`UsageTrendDetail`) with the
/// peak, the date range, the source note, and per-bar highlight. The bars render already-priced per-day
/// numbers (`MetricChartPoint`); this view never computes usage, only draws it.
struct UsageSparkline: View {
    let data: WidgetData
    /// The row's per-day points (the producer already validated and capped them); held directly so the
    /// bars, the popover, and the accessibility label all read one list.
    private let points: [MetricChartPoint]

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var hover = HoverPopoverState()

    /// Widest the bar strip grows to, and a floor so it can't collapse to a sliver next to a long title.
    private static let maxChartWidth: CGFloat = 150
    private static let minChartWidth: CGFloat = 90
    /// Per-bar floor (matches the original app) so a dense window never squashes bars below visibility.
    private static let minBarWidth: CGFloat = 2

    init(data: WidgetData) {
        self.data = data
        self.points = data.chartPoints
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(data.title)
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Anchor the popover to the bar strip (not the whole row), so its arrow points straight up
            // at the chart rather than at the row's center, off to the left of the bars.
            bars
                // Match the spend/reset value affordance: light the sparkline as soon as the pointer
                // arrives, then hold the highlight while its detail popover is open so the chart still
                // reads as the popover's source. `hover.dismiss()` clears both flags on panel close.
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .padding(.horizontal, -7)
                        .padding(.vertical, -4)
                        .opacity(showChartHighlight ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: showChartHighlight)
                // Only the bar strip is hoverable — hovering the title must not reveal the detail.
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
                }
                // Dismissing from outside (click-away) removes the detail view without an `.ended`
                // hover event, so a plain assignment would strand `overDetail == true` and block
                // future hides — reset the whole hover state instead.
                .popover(isPresented: Binding(get: { hover.isPresented }, set: { if !$0 { hover.dismiss() } }),
                         arrowEdge: .top) {
                    UsageTrendDetail(title: data.title, points: points, note: data.chartNote) { inside in
                        hover.detailHover(inside)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { hover.dismiss() }
    }

    /// Immediate pointer affordance plus a persistent source highlight while the popover is visible.
    private var showChartHighlight: Bool {
        hover.overInline || hover.isPresented
    }

    private var bars: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        // The bars use the same blue as a healthy meter (`Theme.meterFill(.normal)`, system blue softened
        // for glass), so the trend reads as part of the card's visual language and tracks light/dark and
        // the accessibility contrast settings like every other bar.
        return HStack(alignment: .bottom, spacing: 1) {
            // Keyed by the day label (unique — the producer collapses duplicate days) so a refresh that
            // adds or drops a day re-lays-out cleanly instead of remapping bars by position.
            ForEach(points, id: \.label) { point in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.meterFill(.normal))
                    .frame(minWidth: Self.minBarWidth, maxWidth: .infinity)
                    .frame(height: barHeight(point.value, max: maxValue))
            }
        }
        .frame(minWidth: Self.minChartWidth, maxWidth: Self.maxChartWidth)
        .frame(height: density.trendChartHeight, alignment: .bottom)
    }

    /// A bar's height: proportional to the window's peak, with a visible floor so a small non-zero day
    /// never collapses to nothing, and a thin stub for a true zero so gaps still read as days.
    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        let height = density.trendChartHeight
        guard value > 0 else { return 2 }
        let ratio = min(1, value / maxValue)
        return max(height * 0.18, height * ratio)
    }

    private var accessibilityLabel: String {
        guard let peak = points.max(by: { $0.value < $1.value }),
              let first = points.first, let last = points.last else { return data.title }
        return "\(data.title): \(points.count) days, \(first.label) to \(last.label), peak \(peak.readout)."
    }
}
