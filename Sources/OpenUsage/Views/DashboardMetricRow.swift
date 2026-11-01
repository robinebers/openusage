import SwiftUI

struct DashboardMetricRow: View {
    let model: DashboardRowModel
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var paceTooltip: String?
    var valueTooltip: String?
    var resetTooltip: String?
    var figure: (AnyView) -> AnyView = { $0 }

    static let font: Font = .system(size: 13)
    static let resetFont: Font = .system(size: 12)

    var body: some View {
        Group {
            switch model.mark {
            case .bar(let fill, let severity, let value, let reset, let isUsedUp):
                VStack(alignment: .leading, spacing: DashboardGrid.barGap) {
                    HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.amountGap) {
                        label
                        valueText(value, severity: severity)
                        Spacer(minLength: DashboardGrid.columnGap)
                        resetText(reset, isUsedUp: isUsedUp)
                    }
                    UsageMeterBar(fill: fill, severity: severity, tintsTrack: isUsedUp)
                        .hoverTooltip(paceTooltip)
                }
            case .value(let text, let detail, let severity):
                HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.columnGap) {
                    label
                    Spacer(minLength: 0)
                    figure(AnyView(
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(text)
                                .foregroundStyle(Self.figureStyle(severity))
                            if let detail {
                                Text(" · \(detail)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .fixedSize()
                        .accessibilityValue(Self.expiryAccessibilityValue(severity) ?? "")
                    ))
                }
            }
        }
        .font(Self.font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(model.label)
            .lineLimit(1)
    }

    /// A figure keeps the row's colour until it warns.
    private static func figureStyle(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        severity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.severityTextColor(severity))
    }

    private static func amountStyle(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        severity == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.severityTextColor(severity))
    }

    static func expiryAccessibilityValue(_ severity: WidgetData.MeterSeverity) -> String? {
        switch severity {
        case .normal: nil
        case .warning: "a reset expires within 7 days"
        case .critical: "a reset expires within 48 hours"
        }
    }

    @ViewBuilder
    private func valueText(_ value: String, severity: WidgetData.MeterSeverity) -> some View {
        let text = Text(value)
            .foregroundStyle(Self.amountStyle(severity))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
            .fixedSize()
        if let onToggleMeterStyle {
            Button(action: onToggleMeterStyle) { text }
                .buttonStyle(.plain)
                .hoverTooltip(valueTooltip)
        } else {
            text
        }
    }

    @ViewBuilder
    private func resetText(_ reset: String?, isUsedUp: Bool) -> some View {
        if let reset {
            let text = Text(reset)
                .font(Self.resetFont)
                .foregroundStyle(Self.amountStyle(isUsedUp ? .critical : .normal))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if let onToggleResetDisplay {
                Button(action: onToggleResetDisplay) { text }
                    .buttonStyle(.plain)
                    .hoverTooltip(resetTooltip)
            } else {
                text
            }
        }
    }
}
