import SwiftUI

struct UsageMeterBar: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity

    static let height = DashboardGrid.barHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.severityColor(severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
        }
        .frame(height: Self.height)
        .animation(Motion.spring, value: fill)
        .accessibilityHidden(true)
    }

    private func fillWidth(track: CGFloat) -> CGFloat {
        guard fill > 0 else { return 0 }
        return max(Self.height, track * min(fill, 1))
    }
}
