import SwiftUI

/// One metric on one row inside an account: label, bar, value and reset in fixed columns, so every bar
/// in the panel starts and ends at the same x. The label is secondary, the value medium in the bar's
/// colour once the bar is orange or red, the reset secondary. While the reading is projected to run
/// out a red flame sits before the value, inside the value column; nothing otherwise, so the columns
/// never move. A reading without a limit (a balance, a
/// count, a status) has no bar: its figure takes the bar's place. A row under the pointer draws as it
/// does at rest; a click on the value flips every row between used and left, a click on the reset
/// between countdown and exact time, where the dashboard supplies `onToggleMeterStyle` and
/// `onToggleResetDisplay`, and resting the pointer tells the one figure the row doesn't show, where the
/// dashboard supplies the tooltips: on the bar where the pace lands at reset, on the value the other
/// reading, on the reset the other format. The dashboard wraps the Limit Resets row's figure in its
/// hover through `figure`. A drag preview and the share image supply none of them, and draw the row
/// inert.
struct DashboardMetricRow: View {
    let model: DashboardRowModel
    /// Flips the global Used/Left meter style. `nil` where the row is static or its value isn't a
    /// Used/Left reading: the value is plain text.
    var onToggleMeterStyle: (() -> Void)?
    /// Flips the global countdown/exact-time reset display. `nil` where the row is static: the reset is
    /// plain text.
    var onToggleResetDisplay: (() -> Void)?
    /// The bar's hover, where the pace lands at reset (`WidgetData.paceTooltip`).
    var paceTooltip: String?
    /// The value's hover, the other reading (`WidgetData.meterStyleTooltip`).
    var valueTooltip: String?
    /// The reset's hover, the other format (`WidgetData.resetTooltip`).
    var resetTooltip: String?
    /// Wraps a value row's figure, so the live dashboard can attach the resets hover to the figure alone.
    var figure: (AnyView) -> AnyView = { $0 }

    /// The row's type: 12 pt, under the 13 pt captions and names.
    static let font: Font = .callout

    var body: some View {
        HStack(spacing: DashboardGrid.columnGap) {
            Text(model.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: DashboardGrid.labelWidth, alignment: .leading)
            switch model.mark {
            case .bar(let fill, let severity, let value, let reset, let flame):
                UsageMeterBar(fill: fill, severity: severity)
                    .hoverTooltip(paceTooltip)
                HStack(spacing: Theme.Spacing.xxs) {
                    if flame {
                        Image(systemName: "flame.fill")
                            .imageScale(.small)
                            .foregroundStyle(Theme.severityColor(.critical))
                            .accessibilityLabel("Running out")
                    }
                    valueText(value, severity: severity)
                }
                .frame(width: DashboardGrid.valueWidth, alignment: .trailing)
                resetColumn(reset)
                    .frame(width: DashboardGrid.resetWidth, alignment: .trailing)
            case .value(let text):
                figure(AnyView(
                    Text(text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .fixedSize()
                ))
                Spacer(minLength: 0)
            }
        }
        .font(Self.font)
        .padding(.horizontal, DashboardGrid.inset)
        .frame(height: DashboardGrid.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The value, in the bar's colour once the bar is orange or red, which flips every row between
    /// used and left on a click where the dashboard supplies the flip; plain text in a preview, in the
    /// share image, and on a badge.
    @ViewBuilder
    private func valueText(_ value: String, severity: WidgetData.MeterSeverity) -> some View {
        let text = Text(value)
            .fontWeight(.medium)
            .foregroundStyle(severity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.severityColor(severity)))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
        if let onToggleMeterStyle {
            Button(action: onToggleMeterStyle) { text }
                .buttonStyle(.plain)
                .hoverTooltip(valueTooltip)
        } else {
            text
        }
    }

    /// The reset: a countdown or a clock time, which flips the display on a click where the dashboard
    /// supplies the flip; plain text in a preview, in the share image, and when there is no live reset.
    @ViewBuilder
    private func resetColumn(_ reset: String?) -> some View {
        let text = Text(reset ?? "")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        if reset != nil, let onToggleResetDisplay {
            Button(action: onToggleResetDisplay) { text }
                .buttonStyle(.plain)
                .hoverTooltip(resetTooltip)
        } else {
            text
        }
    }
}
