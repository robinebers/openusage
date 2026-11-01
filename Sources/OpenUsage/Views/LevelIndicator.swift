import SwiftUI

/// Apple's capacity bar at the height of a row. It's drawn here because `NSLevelIndicator` and `Gauge`
/// both stay 16 pt tall at every control size.
struct LevelIndicator: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    /// Enough for the rounded ends to stay round on a sliver of a level.
    private static let shortestFill: CGFloat = 4

    var body: some View {
        Self.shape
            .fill(Theme.meterTrack)
            .overlay(alignment: .leading) {
                if fill > 0 {
                    GeometryReader { proxy in
                        Self.shape
                            .fill(Theme.severityColor(severity))
                            .frame(width: max(Self.shortestFill, (proxy.size.width * min(fill, 1)).rounded()))
                    }
                }
            }
            .accessibilityHidden(true)
    }
}
