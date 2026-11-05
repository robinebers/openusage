import SwiftUI
import AppKit

enum Theme {
    static let iconGray = AnyShapeStyle(.secondary)

    static func severityColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// The severity colors darkened enough to read as small text on a light panel.
    static func severityTextColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .normal: severityColor(.normal)
        case .warning: adaptive(light: NSColor(red: 0.7, green: 0.37, blue: 0, alpha: 1), dark: .systemOrange)
        case .critical: adaptive(light: NSColor(red: 0.84, green: 0, blue: 0.08, alpha: 1), dark: .systemRed)
        }
    }

    static let notice = AnyShapeStyle(severityColor(.warning))

    static let positive = AnyShapeStyle(severityColor(.normal))

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
    }

    /// The same system colours Settings' grouped `Form` uses, so every screen matches it.
    static let panelBody = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color(nsColor: .quaternarySystemFill)
    static let hairline = adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
    static let meterTrack = adaptive(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.12))
    static let paceMark = Color.primary.opacity(0.55)
    static let skeleton = adaptive(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.086))

    static let controlFill = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.1))
    static let segmentThumb = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.18))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

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
                .fill(Theme.cardFill)
                .overlay { Theme.cardShape.strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }
}
