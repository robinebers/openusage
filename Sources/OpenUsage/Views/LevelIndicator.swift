import SwiftUI

extension EnvironmentValues {
    /// `ImageRenderer` can't draw AppKit controls, so a share image draws its bars as shapes.
    @Entry var drawsLevelsAsShapes = false
}

/// A limit's level as Apple's progress bar, with a tick where it would be at an even pace.
struct LevelIndicator: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity
    var paceMark: Double?

    @Environment(\.drawsLevelsAsShapes) private var drawsAsShapes

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    private static let shortestFill: CGFloat = 4

    var body: some View {
        ZStack {
            if drawsAsShapes {
                shapes
            } else {
                ProgressView(value: min(max(fill, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Theme.severityColor(severity))
                    .accessibilityHidden(true)
            }
            if let paceMark {
                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width * paceMark, y: proxy.size.height / 2)
                    Capsule()
                        .frame(width: 4, height: 14)
                        .position(center)
                        .blendMode(.destinationOut)
                    Capsule()
                        .fill(Theme.paceMark)
                        .frame(width: 2, height: 12)
                        .position(center)
                }
                .accessibilityHidden(true)
            }
        }
        .compositingGroup()
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
