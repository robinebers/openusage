import SwiftUI
import AppKit

enum Theme {
    static let iconGray = AnyShapeStyle(.secondary)

    static func severityColor(_ severity: WidgetData.MeterSeverity?) -> Color {
        switch severity {
        case .normal, nil: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    static let notice = AnyShapeStyle(severityColor(.warning))

    static let positive = AnyShapeStyle(Color(nsColor: .systemGreen))

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
        static let xxxl: CGFloat = 16
    }

    static let trayNSColor: NSColor = .textBackgroundColor
    static var traySurface: Color { Color(nsColor: trayNSColor) }

    static let cardFill = AnyShapeStyle(.fill.quaternary)

    static let cardCornerRadius: CGFloat = 12

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }

    func liftedRowSurface() -> some View {
        cardSurface()
            .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// A grouped form laid out inline in a sheet or a popover screen: sized to its rows instead of
    /// scrolling, and without the extra vertical margin the form adds around itself when it fills a
    /// window.
    func inlineGroupedForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, -16)
    }
}

private struct CardSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            Theme.cardShape
                .fill(Theme.traySurface)
                .overlay { Theme.cardShape.fill(Theme.cardFill) }
        }
    }
}
