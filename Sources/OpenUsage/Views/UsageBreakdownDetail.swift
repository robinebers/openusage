import SwiftUI

/// A history row's hover detail: every measure the provider reported for the row's window, and its top models.
struct UsageBreakdownDetail: View {
    let breakdown: UsageBreakdown
    let providerName: String
    var onHoverChange: (Bool) -> Void

    private static let width: CGFloat = 250
    private static let modelNameWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(breakdown.window.title).fontWeight(.semibold)
                Text(" · \(breakdown.clockNote)").foregroundStyle(.secondary)
            }
            .lineLimit(1)
            VStack(spacing: 2) {
                ForEach(UsageMeasure.allCases, id: \.self) { measure in
                    if let number = breakdown.totals[measure] {
                        HStack(spacing: 8) {
                            Text(measure.title).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(MetricFormatter.number(number, kind: measure.metricValue(number).kind, style: .row))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !breakdown.models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Models by \(breakdown.modelMeasure.title)").foregroundStyle(.secondary)
                    Grid(horizontalSpacing: 6, verticalSpacing: 2) {
                        ForEach(breakdown.models, id: \.name) { model in
                            GridRow {
                                Text(model.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: Self.modelNameWidth, alignment: .leading)
                                UsageMeterBar(fill: model.share, severity: .normal)
                                Text(MetricFormatter.number(model.number, kind: .count, style: .row))
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Text("Only what \(providerName) reported. No prices.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }
}
