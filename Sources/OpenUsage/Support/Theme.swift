import SwiftUI
import AppKit

/// Central palette + surface styles. Surfaces stay adaptive (light/dark).
enum Theme {
    /// Hierarchical secondary tint for the provider marks — the vibrancy-correct gray on glass.
    static let iconGray = AnyShapeStyle(.secondary)

    /// Meter fill for a severity band — the macOS system palette (the battery-style traffic
    /// light), never hand-tuned hexes, so the bars track light/dark and accessibility settings
    /// like every other system meter. Softened through `glassTint`: explicit colors get no
    /// vibrancy adaptation on the popover glass, so full-strength fills glow against the
    /// tempered material around them.
    static func meterFill(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        glassTint(meterColor(severity))
    }

    private static func meterColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// How much of the saturated color survives the glass softening (1 = full strength).
    static let glassTintStrength = 0.8

    /// Wraps a saturated color for use on the popover glass: blended toward a per-scheme neutral
    /// so the material tempers it the way vibrancy tempers semantic styles. Increase Contrast
    /// bypasses the fade (Apple: every custom color on glass needs an increased-contrast variant).
    static func glassTint(_ color: Color, strength: Double = glassTintStrength) -> AnyShapeStyle {
        AnyShapeStyle(GlassTint(color: color, strength: strength))
    }

    /// Inline notice/alert tint (refresh warning triangle, pin-limit notice, settings errors) —
    /// the system orange softened for glass like the meter fills.
    static let notice = glassTint(Color(nsColor: .systemOrange))

    /// Card surface in the default (glass) state — toggle off: a barely-there semantic quaternary
    /// tint, so cards read as light translucent panels over the live popover glass (the Control
    /// Center module look). Semantic, so it tracks light/dark and accessibility settings.
    static let cardFill = AnyShapeStyle(.quaternary)

    /// Card surface when Reduce Transparency is on — toggle on: a frosted material instead of the
    /// barely-there tint, so each card reads as a distinct raised panel over the now-opaque popover.
    /// `.thinMaterial` is the lightest frost that separates the card from the solid background; bump
    /// to `.regularMaterial` here if cards need to read more solid.
    static let frostedCardFill = AnyShapeStyle(Material.thin)

    /// Backing for lifted drag previews: material, so the floating card stays legible over the rows
    /// it passes instead of letting them bleed through a translucent fill.
    static let liftedCardFill = AnyShapeStyle(Material.regular)

    /// Hairline outline on live cards when Reduce Transparency is on. The frosted fill alone
    /// separates cards well in light mode but barely at all in dark mode (a material lightens little
    /// over a dark background, so card and popover end up nearly the same tone). A defined edge fixes
    /// that deterministically in both modes — the same way macOS grouped boxes (System Settings,
    /// Control Center) read in dark mode. `.separator` is the semantic hairline, so it tracks
    /// light/dark and Increase Contrast. (Not drawn in the default glass state — see
    /// `CardSurfaceModifier` — so the toggle-off look is unchanged.)
    static let cardBorder = AnyShapeStyle(.separator)

    /// The single corner radius for every metric/settings card surface and its lifted twin, so the
    /// floating drag preview always matches the live card's shape.
    static let cardCornerRadius: CGFloat = 12

    /// The rounded rectangle shared by every card surface (live and lifted), so the shape is defined once.
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// The grouped-card surface used for provider/settings cards, in the shared rounded shape. The
    /// live fill follows the Reduce Transparency setting via `CardSurfaceModifier` (a modifier, not a
    /// plain func, so it can read the environment flag): the original translucent quaternary fill
    /// with the toggle off, or the frosted material plus a hairline border with it on (so cards stay
    /// distinct from the opaque popover, including dark mode). Pass `lifted: true` for the floating
    /// drag preview, which swaps the fill for the heavier lifted material and skips the border (its
    /// shadow/`liftedRowSurface` hairline already detaches it). Routing every card site through this
    /// keeps the live card and its lifted twin one shape.
    func cardSurface(lifted: Bool = false) -> some View {
        modifier(CardSurfaceModifier(lifted: lifted))
    }

    /// A single-row lifted preview surface: the card fill plus the thin separator hairline that
    /// fences a free-floating one-row chip off from the rows beneath it (the multi-row provider
    /// previews don't take the hairline — the card outline alone reads as detached there).
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

/// Saturated tint softened for Liquid Glass; Increase Contrast resolves to the full-strength
/// color (whose system-color base also swaps to its high-contrast variant through the
/// appearance). The blend is opaque rather than alpha-faded on purpose: a translucent fill
/// picks up whatever sits beneath it (the meter fill sits on the quaternary track, the flame
/// glyph on the card), so the "same" color would read differently per backdrop. Mixing toward
/// a fixed per-scheme neutral keeps every use of one severity color identical.
private struct GlassTint: ShapeStyle {
    var color: Color
    var strength: Double

    func resolve(in environment: EnvironmentValues) -> Color {
        // Increase Contrast and Reduce Transparency both want the full-strength color: the first by
        // Apple's rule (every custom color on glass needs a high-contrast variant), the second
        // because in solid mode there's no glass to temper against, so the softened fade would just
        // read as a washed-out bar.
        guard environment.colorSchemeContrast != .increased,
              !environment.reduceTransparencyEffective
        else { return color }
        let neutral = environment.colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.94)
        return color.mix(with: neutral, by: 1 - strength)
    }
}

/// Backs `cardSurface`. With Reduce Transparency *off* (the default) live cards keep the original
/// look exactly: the translucent quaternary fill and no border, so the toggle-off appearance is
/// unchanged from before this setting existed. With it *on*, cards take the frosted fill plus the
/// hairline border so they stay distinct over the now-opaque popover (the border is what carries
/// that separation in dark mode). The lifted drag preview always uses its own legible material and
/// no border. A `ViewModifier` rather than a plain `View` func so it can read the environment flag.
private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.reduceTransparencyEffective) private var reduceTransparency
    let lifted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if lifted {
            content.background(Theme.liftedCardFill, in: Theme.cardShape)
        } else if reduceTransparency {
            content
                .background(Theme.frostedCardFill, in: Theme.cardShape)
                .overlay { Theme.cardShape.strokeBorder(Theme.cardBorder, lineWidth: 0.5) }
        } else {
            content.background(Theme.cardFill, in: Theme.cardShape)
        }
    }
}

/// Whether the popover is rendering in its solid, non-glass form — the app's Reduce Transparency
/// toggle OR'd with macOS's own accessibility setting, resolved once in `DashboardView` and pushed
/// down so every surface (cards, buttons, meter tints) reads the same answer. Defaults to `false`
/// (full Liquid Glass) so nothing changes unless the flag is injected.
private struct ReduceTransparencyEffectiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reduceTransparencyEffective: Bool {
        get { self[ReduceTransparencyEffectiveKey.self] }
        set { self[ReduceTransparencyEffectiveKey.self] = newValue }
    }
}
