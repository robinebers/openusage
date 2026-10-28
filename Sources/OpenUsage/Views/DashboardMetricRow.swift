import SwiftUI

struct DashboardMetricRow: View {
    let model: DashboardRowModel
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var paceTooltip: String?
    var valueTooltip: String?
    var resetTooltip: String?
    var figure: (AnyView) -> AnyView = { $0 }

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
