import SwiftUI
import AppKit

/// Central palette + surface styles. Surfaces stay adaptive (light/dark).
///
/// By default the popover is a solid, opaque panel; the opt-in Increase Transparency mode (and the
/// secret-code egg) make it translucent. Either way, Liquid Glass is reserved for the footer/top-bar
/// chrome — the controls/navigation layer — and never the data cards: Apple's guidance is to keep
/// Liquid Glass out of the content layer and back content with standard materials instead. The data
/// region mirrors the macOS System Settings grouped look: a page "tray" with borderless grouped cards
/// lifted off it by the system's own `.fill.quaternary` (no hand-tuned values), so it adapts to
/// light/dark like every other Mac app. Under the translucent treatment the cards swap their opaque
/// base for a frosted standard material so text stays legible (see `cardSurface`).
enum Theme {
    /// Hierarchical secondary tint for the provider marks.
    static let iconGray = AnyShapeStyle(.secondary)

    /// Meter fill for a severity band — the macOS system palette (the battery-style traffic light),
    /// never hand-tuned hexes, so the bars track light/dark and accessibility settings like every
    /// other system meter. Full strength: on the opaque surface there's no glass to temper against.
    static func meterFill(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        AnyShapeStyle(meterColor(severity))
    }

    private static func meterColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// Inline notice/alert tint (refresh warning triangle, pin-limit notice, settings errors) — the
    /// system orange at full strength, matching the meter fills.
    static let notice = AnyShapeStyle(Color(nsColor: .systemOrange))

    /// Inline success tint (the "screenshot copied to clipboard" confirmation) — the system green at
    /// full strength, the positive counterpart to `notice`'s orange.
    static let positive = AnyShapeStyle(Color(nsColor: .systemGreen))

    // MARK: - Surfaces

    /// The popover's opaque backdrop ("tray") behind the grouped cards — `textBackgroundColor`, the
    /// bright page surface document/Notes views use (white in light, near-black in dark; it does not
    /// pick up desktop wallpaper tint). Exposed as an `NSColor` so the panel's AppKit backdrop
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
    /// The grouped-card surface used for provider/settings cards, in the shared rounded shape: the
    /// bright page base lifted by the system's `.fill.quaternary` (the System Settings grouped-box
    /// look), borderless — the subtle fill carries the grouping the way Settings does, in both light
    /// and dark. Drawing the opaque page base first keeps a lifted drag preview solid while it floats.
    /// `lifted` is accepted for call-site symmetry; live and lifted cards share one surface (the lift's
    /// depth comes from `ReorderLiftPreview`'s shadow, not a different fill).
    func cardSurface(lifted: Bool = false) -> some View {
        modifier(CardSurfaceModifier(lifted: lifted))
    }

    /// A single-row lifted preview surface: the card surface plus a thin separator hairline that fences
    /// a free-floating one-row chip off from the rows beneath it (the multi-row provider previews don't
    /// take the hairline — their shadow alone reads as detached).
    func liftedRowSurface() -> some View {
        cardSurface(lifted: true)
            .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// The trailing on/off switch styling shared by every settings + Customize row toggle: no inline
    /// label (the row's leading text is the label), the native switch style, small control size.
    func settingsSwitchStyle() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// Backs `cardSurface`. The grouped card surface: the opaque page base (`traySurface`) with the
/// system's `.fill.quaternary` composited on top — borderless, matching the macOS System Settings
/// grouped box in both light and dark. The opaque base means a lifted drag preview stays solid while
/// it floats; the page base under a live card is the same color as the tray behind it, so it's
/// invisible there. `lifted` is unused — both paths share the one surface.
///
/// Under the translucent surface treatment (Increase Transparency / the secret-code egg) the opaque page base
/// is dropped so the behind-window vibrancy backdrop shows through, while the system grouped fill stays
/// so cards still read as grouped boxes over the desktop.
private struct CardSurfaceModifier: ViewModifier {
    let lifted: Bool
    @Environment(\.popoverSurfaceTreatment) private var treatment

    func body(content: Content) -> some View {
        content.background {
            switch treatment {
            case .opaque:
                Theme.cardShape
                    .fill(Theme.traySurface)
                    .overlay { Theme.cardShape.fill(Theme.cardFill) }
            case .translucent:
                // Increase Transparency, party, and drunk: the card carries its own frosted
                // `.regularMaterial` so metric text stays legible over whatever shows through the
                // behind-window backdrop (the desktop, or the party tint over it), with `.fill.quaternary`
                // on top preserving the grouped-card hierarchy. HIG: back content-layer surfaces with a
                // standard material — a bare low-opacity fill over the desktop is the "washed out"
                // anti-pattern. This is a standard material, not `glassEffect`: Liquid Glass stays in the
                // chrome layer, not the content cards.
                Theme.cardShape
                    .fill(.regularMaterial)
                    .overlay { Theme.cardShape.fill(Theme.cardFill) }
            }
        }
    }
}
