import SwiftUI
import AppKit

/// Central palette + surface styles. Surfaces stay adaptive (light/dark).
///
/// The popover is a solid, opaque panel. Liquid Glass is reserved for the footer/top-bar
/// chrome — the controls/navigation layer — and never the data cards: Apple's guidance is to keep
/// Liquid Glass out of the content layer and back content with standard materials instead. The data
/// region mirrors the macOS System Settings grouped look: a page "tray" with borderless grouped cards
/// lifted off it by the system's own `.fill.quaternary` (no hand-tuned values), so it adapts to
/// light/dark like every other Mac app.
enum Theme {
    /// Hierarchical secondary tint for the provider marks.
    static let iconGray = AnyShapeStyle(.secondary)

    /// The one severity palette: blue, orange, red. Every severity-coloured element (meter fills, hover
    /// text, reset dots, claim banners) takes its colour from here, so a severity reads
    /// the same everywhere. `nil` is normal. System colours, never `.accentColor` (it follows the
    /// user's accent setting) or hand-tuned values, so they track light/dark and Increase Contrast.
    static func severityColor(_ severity: WidgetData.MeterSeverity?) -> Color {
        switch severity {
        case .normal, nil: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// Inline notice/alert tint (refresh warning triangle, pin-limit notice, settings errors) — the
    /// palette's warning orange.
    static let notice = AnyShapeStyle(severityColor(.warning))

    /// Inline success tint (the "screenshot copied to clipboard" confirmation) — the system green at
    /// full strength, the positive counterpart to `notice`'s orange.
    static let positive = AnyShapeStyle(Color(nsColor: .systemGreen))

    // MARK: - Spacing

    /// The one spacing scale. Every gap and padding in `PanelMetrics` and `DashboardBox` is a step on
    /// it, so the panel has one rhythm and no density levels.
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

    // MARK: - Surfaces

    /// The popover's opaque backdrop ("tray") behind the grouped cards — `textBackgroundColor`, the
    /// bright page surface document/Notes views use (white in light, near-black in dark; it does not
    /// pick up desktop wallpaper tint). Exposed as an `NSColor` so the panel's window background
    /// (`StatusItemController`) and the SwiftUI surface (`DashboardView.PopoverSurface`) are one color.
    /// The footer's frosted glass bar samples this opaque tray (in-window), so it reads as glass chrome
    /// over solid content, never a hole to the desktop. The grouped cards sit on it (see `cardSurface`).
    static let trayNSColor: NSColor = .textBackgroundColor
    static var traySurface: Color { Color(nsColor: trayNSColor) }

    /// The semantic fill that lifts a grouped card off the `traySurface` page — `.fill.quaternary`, the
    /// system's own subtle grouped fill (≈ the macOS System Settings grouped box: `#F9F9F9` over white
    /// in light, a step lighter than the page in dark). No hand-tuned values; it tracks light/dark and
    /// Increase Contrast. Composited over the opaque page in `cardSurface`, so the card is opaque (a
    /// lifted drag preview stays solid while it floats).
    static let cardFill = AnyShapeStyle(.fill.quaternary)

    /// The single corner radius for every metric/settings card surface and its lifted twin, so the
    /// floating drag preview always matches the live card's shape.
    static let cardCornerRadius: CGFloat = 12

    /// The rounded rectangle shared by every card surface (live and lifted), so the shape is defined once.
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// The grouped-card surface used for provider and account cards, in the shared rounded shape: the
    /// bright page base lifted by the system's `.fill.quaternary` (the System Settings grouped-box
    /// look), borderless — the subtle fill carries the grouping the way Settings does, in both light
    /// and dark. Drawing the opaque page base first keeps a lifted drag preview solid while it floats;
    /// the preview's depth comes from `ReorderLiftPreview`'s shadow, not a different card surface.
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }

    /// A single-row lifted preview surface: the card surface plus a thin separator hairline that fences
    /// a free-floating one-row chip off from the rows beneath it (the multi-row provider previews don't
    /// take the hairline — their shadow alone reads as detached).
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

/// Backs `cardSurface`. The grouped card surface: the opaque page base (`traySurface`) with the
/// system's `.fill.quaternary` composited on top — borderless, matching the macOS System Settings
/// grouped box in both light and dark. The opaque base means a lifted drag preview stays solid while
/// it floats; the page base under a live card is the same color as the tray behind it, so it's
/// invisible there. Live cards and drag previews share the same surface.
private struct CardSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            Theme.cardShape
                .fill(Theme.traySurface)
                .overlay { Theme.cardShape.fill(Theme.cardFill) }
        }
    }
}
