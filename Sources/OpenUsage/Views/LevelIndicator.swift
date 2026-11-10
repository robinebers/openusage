import SwiftUI

extension EnvironmentValues {
    /// `ImageRenderer` can't draw AppKit controls, so a share image draws its bars as shapes.
    @Entry var drawsLevelsAsShapes = false
}

/// A limit's level as Apple's progress bar, with a tick where it would be at an even pace. Drawn as shapes, it
/// can mark in red the stretch of a unified bar held by accounts that are used up.
struct LevelIndicator: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity
    var paceMark: Double?
    var usedUp: ClosedRange<Double>?

    @Environment(\.drawsLevelsAsShapes) private var drawsAsShapes

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    private static let shortestFill: CGFloat = 4

    var body: some View {
        level
            .overlay {
                if let paceMark {
                    Capsule()
                        .fill(Theme.paceMark)
                        .frame(width: 2, height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visualEffect { content, proxy in content.offset(x: proxy.size.width * paceMark - 1) }
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private var level: some View {
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
            .overlay(alignment: .leading) {
                if let usedUp {
                    GeometryReader { proxy in
                        Self.shape
                            .fill(Theme.severityColor(.critical).opacity(0.45))
                            .frame(width: (proxy.size.width * (usedUp.upperBound - usedUp.lowerBound)).rounded())
                            .offset(x: (proxy.size.width * usedUp.lowerBound).rounded())
                    }
                }
            }
            .accessibilityHidden(true)
    }
}
