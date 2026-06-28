import SwiftUI

extension View {
    /// The "too much transparency" easter-egg treatment, applied as one stable modifier so enabling and
    /// disabling **crossfade** (a ~0.55s ease) instead of snapping.
    ///
    /// - `.disco`: the secret code's main state — a loud but **readable** party. A vivid churning
    ///   gradient fills the popover behind the content and a glowing rim rotates around the edge, while
    ///   the content stays crisp on frosted cards (no blur over text). Meter bars and provider marks join
    ///   in via the `popoverPartyMode` environment flag.
    /// - `.ghost`: the "Even More" extreme — the deliberately barely-readable pink-glass chaos, layered
    ///   *over* the content (blur, pink wash, sway) with the window going see-through.
    /// - `.opaque` / `.increased`: nothing — just the normal look.
    func tooMuchTransparency(_ style: PopoverTransparencyStyle) -> some View {
        modifier(TooMuchTransparencyModifier(style: style))
    }
}

/// Shared party palette — pink, violet, cyan, rose.
private let discoColors: [Color] = [
    Color(red: 1.00, green: 0.32, blue: 0.74),
    Color(red: 0.62, green: 0.40, blue: 1.00),
    Color(red: 0.30, green: 0.85, blue: 1.00),
    Color(red: 1.00, green: 0.55, blue: 0.86),
    Color(red: 1.00, green: 0.32, blue: 0.74),
]

/// One stable modifier whose layers come and go by `style`. The `.animation(value:)` plus per-layer
/// `.transition(.opacity)` is what makes toggling the egg fade in and out (the AppKit window alpha and
/// backdrop crossfade on the same ~0.55s ease, driven by `StatusItemController`).
private struct TooMuchTransparencyModifier: ViewModifier {
    let style: PopoverTransparencyStyle

    private var isDisco: Bool { style == .disco }
    private var isGhost: Bool { style == .ghost }

    func body(content: Content) -> some View {
        content
            .modifier(GhostDistortion(active: isGhost))
            .background {
                if isDisco { DiscoBackdrop().transition(.opacity) }
            }
            .overlay {
                if isDisco { DiscoRim().transition(.opacity).allowsHitTesting(false) }
            }
            .overlay {
                if isGhost { GhostOverlays().transition(.opacity).allowsHitTesting(false) }
            }
            .environment(\.popoverPartyMode, isDisco)
            .animation(.easeInOut(duration: 0.55), value: style)
    }
}

// MARK: - Disco (loud but readable)

/// A vivid, slowly churning gradient that fills the popover behind the (frosted, readable) content.
private struct DiscoBackdrop: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                AngularGradient(colors: discoColors, center: .center, angle: .degrees(t * 28))
                RadialGradient(
                    colors: [Color.white.opacity(0.22), .clear],
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
private struct DiscoRim: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    AngularGradient(colors: discoColors, center: .center, angle: .degrees(-t * 36)),
                    lineWidth: 2.5
                )
                .shadow(color: Color(red: 1, green: 0.4, blue: 0.85).opacity(0.7), radius: 7)
        }
    }
}

// MARK: - Ghost (the unreadable "Even More" extreme)

/// Blurs, hue-wobbles, and gently sways the content — the unreadable part. Identity when inactive (no
/// `TimelineView` mounted), so it costs nothing outside the egg.
private struct GhostDistortion: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                content
                    .saturation(1.55)
                    .blur(radius: 3.6)
                    .hueRotation(.degrees(sin(t * 1.1) * 16))
                    .scaleEffect(1.05 * (1 + sin(t * 1.2) * 0.018))   // over-scale hides sway gaps
                    .rotationEffect(.degrees(sin(t * 1.5) * 1.1))
            }
        } else {
            content
        }
    }
}

/// The pink-glass chaos layered over the content: a clear-glass lens (the deliberate Liquid Glass
/// abuse), a pink wash, and a drifting specular shimmer.
private struct GhostOverlays: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                glassLens()
                AngularGradient(colors: discoColors, center: .center, angle: .degrees(t * 26))
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
