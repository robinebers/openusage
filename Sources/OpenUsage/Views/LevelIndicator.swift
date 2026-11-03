import SwiftUI

extension EnvironmentValues {
    /// `ImageRenderer` can't draw AppKit controls, so a share image draws its bars as shapes.
    @Entry var drawsLevelsAsShapes = false
}

/// A limit's level as Apple's progress bar.
struct LevelIndicator: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity

    @Environment(\.drawsLevelsAsShapes) private var drawsAsShapes

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    private static let shortestFill: CGFloat = 4

    var body: some View {
        if drawsAsShapes {
            shapes
        } else {
            ProgressView(value: min(max(fill, 0), 1))
                .progressViewStyle(.linear)
                .tint(Theme.severityColor(severity))
                .accessibilityHidden(true)
        }
    }

    private var shapes: some View {
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
