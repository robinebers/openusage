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

/// One stable modifier whose layers come and go by `style`. The `.animation(value:)` plus per-layer
/// `.transition(.opacity)` is what makes toggling the egg fade in and out (the AppKit window alpha and
/// backdrop crossfade on the same ~0.55s ease, driven by `StatusItemController`).
private struct TooMuchTransparencyModifier: ViewModifier {
    let style: PopoverTransparencyStyle

    private var isParty: Bool { style == .party }
    private var isDrunk: Bool { style == .drunk }

    func body(content: Content) -> some View {
        content
            .modifier(DrunkDistortion(active: isDrunk))
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
    @Environment(\.popoverIsVisible) private var shown

    var body: some View {
        // The churning clock is mounted only while the popover is on-screen; closed, it drops to a static
        // frame so no display link ticks (see `\.popoverIsVisible`).
        if shown {
            TimelineView(.animation) { timeline in
                gradient(at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else {
            // Static frame at the current instant: matches the live clock's first frame, so the (at most
            // one-frame) static render during a show is indistinguishable from the running animation.
            gradient(at: Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        }
    }

    private func gradient(at t: TimeInterval) -> some View {
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

/// A glowing rim that rotates around the popover edge — pure party, never over the text.
private struct PartyRim: View {
    @Environment(\.popoverIsVisible) private var shown

    var body: some View {
        if shown {
            TimelineView(.animation) { timeline in
                rim(at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else {
            rim(at: Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        }
    }

    private func rim(at t: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(
                AngularGradient(colors: partyColors, center: .center, angle: .degrees(-t * 36)),
                lineWidth: 2.5
            )
            .shadow(color: Color(red: 1, green: 0.4, blue: 0.85).opacity(0.7), radius: 7)
    }
}

// MARK: - Drunk (the woozy, barely-readable escalation)

/// Blurs, hue-wobbles, and woozily sways the content — the "had one too many" part. Identity when
/// inactive (no `TimelineView`, no effect), so it costs nothing outside the egg. While Drunk is active the
/// sway clock is mounted only with the popover on-screen (a fresh mount on in-place activation starts it
/// immediately, unlike the reverted `.animation(paused:)` overload); when Drunk is active but the popover
/// is hidden it freezes the distortion at a static frame rather than dropping it, so the look doesn't snap
/// off on close. The three branches are deliberate — collapsing active-but-hidden into the inactive branch
/// would visibly remove the blur the instant the popover closes.
private struct DrunkDistortion: ViewModifier {
    let active: Bool
    @Environment(\.popoverIsVisible) private var shown

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && shown {
            TimelineView(.animation) { timeline in
                distort(content, at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else if active {
            distort(content, at: Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        } else {
            content
        }
    }

    private func distort(_ content: Content, at t: TimeInterval) -> some View {
        content
            .saturation(1.55)
            .blur(radius: 3.6)
            .hueRotation(.degrees(sin(t * 1.1) * 16))
            .scaleEffect(1.05 * (1 + sin(t * 1.2) * 0.018))   // over-scale hides sway gaps
            .rotationEffect(.degrees(sin(t * 1.5) * 1.1))     // the room is spinning
    }
}

/// The pink-glass haze layered over the content: a clear-glass lens (the deliberate Liquid Glass abuse)
/// and a slowly churning pink wash — double-vision territory.
private struct DrunkOverlays: View {
    @Environment(\.popoverIsVisible) private var shown

    var body: some View {
        if shown {
            TimelineView(.animation) { timeline in
                haze(at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else {
            haze(at: Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        }
    }

    private func haze(at t: TimeInterval) -> some View {
        ZStack {
            glassLens()
            AngularGradient(colors: partyColors, center: .center, angle: .degrees(t * 26))
                .opacity(0.5)
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
