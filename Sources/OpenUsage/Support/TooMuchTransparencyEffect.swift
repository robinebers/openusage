import SwiftUI

extension View {
    /// The "too much transparency" easter-egg treatment, applied as one stable modifier so enabling and
    /// disabling **crossfade** (a ~0.55s ease) instead of snapping.
    ///
    /// - `.party`: the secret code's main state — a loud but **readable** party. A vivid churning
    ///   gradient fills the popover behind the content and a glowing rim rotates around the edge, while
    ///   the content stays crisp on frosted cards (no blur over text). Meter bars and provider marks join
    ///   in via the `popoverPartyMode` environment flag.
    /// - `.drunk`: the "Drunk Mode" escalation — properly tipsy: the deliberately barely-readable
    ///   pink-glass chaos layered *over* the content (blur, pink wash, a woozy sway) with the window
    ///   going see-through.
    /// - `.opaque` / `.increased`: nothing — just the normal look.
    func tooMuchTransparency(_ style: PopoverTransparencyStyle) -> some View {
        modifier(TooMuchTransparencyModifier(style: style))
    }
}

/// Shared party palette — a cocktail of hot pink, violet, teal, and amber.
private let partyColors: [Color] = [
    Color(red: 1.00, green: 0.32, blue: 0.74),
    Color(red: 0.62, green: 0.40, blue: 1.00),
    Color(red: 0.30, green: 0.85, blue: 0.95),
    Color(red: 1.00, green: 0.72, blue: 0.30),
    Color(red: 1.00, green: 0.32, blue: 0.74),
]

/// The keepalive runs far below the display's refresh: its only job is to out-pace the compositor's idle
/// layer-cull (~1s of no repaint), and its blur is sub-pixel so the low cadence is invisible. The visible
/// party animations, by contrast, run at the display's native rate (matching the user's refresh, ProMotion
/// included) so they look exactly as designed — the energy win comes from pausing when the popover is
/// hidden (see `\.popoverIsVisible`), not from capping the frame rate.
private let keepAliveFrameInterval: Double = 1.0 / 10.0

/// One stable modifier whose layers come and go by `style`. The `.animation(value:)` plus per-layer
/// `.transition(.opacity)` is what makes toggling the egg fade in and out (the AppKit window alpha and
/// backdrop crossfade on the same ~0.55s ease, driven by `StatusItemController`).
private struct TooMuchTransparencyModifier: ViewModifier {
    let style: PopoverTransparencyStyle

    private var isParty: Bool { style == .party }
    private var isDrunk: Bool { style == .drunk }
    /// Increase Transparency (`.increased`) and party both show *static* content on the translucent,
    /// non-key panel, which the compositor culls unless it keeps repainting; drunk is exempt because
    /// `DrunkDistortion` already repaints it every frame.
    private var needsKeepAlive: Bool { style.surfaceTreatment == .translucent && !isDrunk }

    func body(content: Content) -> some View {
        content
            .modifier(DrunkDistortion(active: isDrunk))
            // Keep translucent static content continuously re-rasterizing so it survives losing key
            // focus, the same way drunk's `DrunkDistortion` animation does (drunk never blanks for
            // exactly this reason). Covers the plain Increase Transparency surface too, not only party —
            // both blank otherwise on a Space switch or Cmd-Tab.
            .modifier(TranslucentKeepAlive(active: needsKeepAlive))
            .background {
                if isParty { PartyBackdrop().transition(.opacity) }
            }
            .overlay {
                if isParty { PartyRim().transition(.opacity).allowsHitTesting(false) }
            }
            .overlay {
                if isDrunk { DrunkOverlays().transition(.opacity).allowsHitTesting(false) }
            }
            .environment(\.popoverPartyMode, isParty)
            .animation(.easeInOut(duration: 0.55), value: style)
    }
}

// MARK: - Party (loud but readable)

/// A vivid, slowly churning gradient that **tints** the popover, sitting behind the (frosted, readable)
/// content. Built on the same translucent foundation as Increase Transparency: it's deliberately
/// semi-transparent so the behind-window vibrancy backdrop — the blurred desktop — shows through and
/// blends with the party colors, rather than an opaque wall that hides it. (A SwiftUI `blendMode` can't
/// composite against the AppKit vibrancy view behind the host, so the desktop only blends through via
/// alpha — hence the reduced opacity rather than a blend mode.)
private struct PartyBackdrop: View {
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                AngularGradient(colors: partyColors, center: .center, angle: .degrees(t * 28))
                    .opacity(0.5)   // translucent tint, so the blurred desktop blends through the colors
                RadialGradient(
                    colors: [Color.white.opacity(0.15), .clear],
                    center: UnitPoint(x: 0.5 + cos(t * 0.5) * 0.3, y: 0.5 + sin(t * 0.6) * 0.3),
                    startRadius: 0,
                    endRadius: 240
                )
                .blendMode(.plusLighter)
            }
        }
    }
}

/// A glowing rim that rotates around the popover edge — pure party, never over the text.
private struct PartyRim: View {
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    AngularGradient(colors: partyColors, center: .center, angle: .degrees(-t * 36)),
                    lineWidth: 2.5
                )
                .shadow(color: Color(red: 1, green: 0.4, blue: 0.85).opacity(0.7), radius: 7)
        }
    }
}

/// Keeps a translucent content layer resident while the panel isn't the key window — for both the plain
/// Increase Transparency surface and party.
///
/// On a non-opaque, non-key window the compositor drops *static* SwiftUI content — only views that
/// repaint every frame survive. That's why, with focus elsewhere (Cmd-Tab, clicking another app,
/// switching Spaces), an animated layer stays but the static cards/text blank out, and why drunk mode
/// (whose whole content is animated by `DrunkDistortion`) never blanks. This forces a re-raster each
/// frame with a *varying* sub-pixel blur — a transform/scale wouldn't, since those reuse the cached
/// bitmap, whereas a changing blur re-renders the content.
///
/// Crucially it runs ONLY while the popover is NOT the key window (`!isKey`): a focused popover isn't
/// culled, so there's nothing to fight and the content must stay perfectly crisp — running the blur then
/// is the visible "pulsing" regression. So while focused this is identity (plain content); it engages
/// only once focus leaves, where the sub-pixel blur on the now-background popover is unnoticeable. Also
/// identity when inactive or hidden, so it costs nothing on the opaque surface or a closed popover.
private struct TranslucentKeepAlive: ViewModifier {
    let active: Bool
    @Environment(\.popoverIsVisible) private var isVisible
    @Environment(\.popoverIsKey) private var isKey

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && !isKey {
            // Low cadence (the blur is sub-pixel, so it's invisible) and paused while the popover is
            // hidden — when it's not on-screen the layer can't be culled, so the keepalive isn't needed.
            TimelineView(.animation(minimumInterval: keepAliveFrameInterval, paused: !isVisible)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                content.blur(radius: (1 + sin(t * 1.8)) * 0.3)   // 0–0.6pt, oscillating; forces a re-raster
            }
        } else {
            content
        }
    }
}

// MARK: - Drunk (the woozy, barely-readable escalation)

/// Blurs, hue-wobbles, and woozily sways the content — the "had one too many" part. Identity when
/// inactive (no `TimelineView` mounted), so it costs nothing outside the egg.
private struct DrunkDistortion: ViewModifier {
    let active: Bool
    @Environment(\.popoverIsVisible) private var isVisible

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(paused: !isVisible)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                content
                    .saturation(1.55)
                    .blur(radius: 3.6)
                    .hueRotation(.degrees(sin(t * 1.1) * 16))
                    .scaleEffect(1.05 * (1 + sin(t * 1.2) * 0.018))   // over-scale hides sway gaps
                    .rotationEffect(.degrees(sin(t * 1.5) * 1.1))     // the room is spinning
            }
        } else {
            content
        }
    }
}

/// The pink-glass haze layered over the content: a clear-glass lens (the deliberate Liquid Glass abuse),
/// a pink wash, and a drifting specular shimmer — double-vision territory.
private struct DrunkOverlays: View {
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                glassLens()
                AngularGradient(colors: partyColors, center: .center, angle: .degrees(t * 26))
                    .opacity(0.5)
                RadialGradient(
                    colors: [Color.white.opacity(0.55), .clear],
                    center: UnitPoint(x: 0.5 + cos(t * 0.8) * 0.32, y: 0.5 + sin(t * 0.9) * 0.32),
                    startRadius: 0,
                    endRadius: 130
                )
                .blendMode(.plusLighter)
            }
        }
    }

    @ViewBuilder
    private func glassLens() -> some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}
