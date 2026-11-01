import SwiftUI

struct UsageMeterBar: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity
    var tintsTrack = false

    static let height = DashboardGrid.barHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(Theme.severityColor(severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
        }
        .frame(height: Self.height)
        .animation(Motion.spring, value: fill)
        .accessibilityHidden(true)
    }

    private var track: AnyShapeStyle {
        tintsTrack ? AnyShapeStyle(Theme.severityColor(severity).opacity(0.24)) : AnyShapeStyle(Theme.meterTrack)
    }

    private func fillWidth(track: CGFloat) -> CGFloat {
        guard fill > 0 else { return 0 }
        return max(Self.height, track * min(fill, 1))
    }
}
