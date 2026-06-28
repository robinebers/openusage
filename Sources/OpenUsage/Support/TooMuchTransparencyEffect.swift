import SwiftUI

extension View {
    /// The "too much transparency" easter-egg treatment.
    ///
    /// - `.disco`: the secret code's main state — a loud but **readable** party. A vivid churning
    ///   gradient fills the popover behind the content and a glowing rim rotates around the edge, while
    ///   the content stays crisp on frosted cards (no blur over text, the window stays solid). Meter bars
    ///   and provider marks join in via the `popoverPartyMode` environment flag.
    /// - `.ghost`: the "Even More" extreme — the deliberately barely-readable pink-glass chaos, where the
    ///   abuse is layered *over* the content (blur, pink wash, sway) and the window goes see-through.
    /// A no-op for the normal and increased styles.
    @ViewBuilder
    func tooMuchTransparency(_ style: PopoverTransparencyStyle) -> some View {
        switch style {
        case .disco:
            modifier(DiscoModifier())
        case .ghost:
            modifier(GhostModifier())
        case .opaque, .increased:
            self
        }
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

// MARK: - Disco (loud but readable)

private struct DiscoModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Leaf views (meters, provider marks) read this to join the party.
            .environment(\.popoverPartyMode, true)
            // The gradient lives BEHIND the content (which sits on frosted scrim cards), so text never
            // gets washed or blurred — that's what keeps it readable.
            .background { DiscoBackdrop() }
            .overlay { DiscoRim().allowsHitTesting(false) }
    }
}

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

/// The deliberately barely-readable chaos: pink iridescence and a clear-glass lens layered *over* the
/// content, which is blurred, hue-wobbled, and gently swaying. The joke leans into abusing Liquid Glass.
private struct GhostModifier: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let spin = t * 26
            let hueWobble = sin(t * 1.1) * 16
            let sway = sin(t * 1.5) * 1.1
            let breathe = 1 + sin(t * 1.2) * 0.018
            let driftX = cos(t * 0.8) * 0.32
            let driftY = sin(t * 0.9) * 0.32

            content
                .saturation(1.55)
                .blur(radius: 3.6)
                .hueRotation(.degrees(hueWobble))
                .scaleEffect(1.05 * breathe)        // over-scale hides sway gaps at the rounded corners
                .rotationEffect(.degrees(sway))
                .overlay { glassLens().allowsHitTesting(false) }
                .overlay { pinkWash(angle: spin).allowsHitTesting(false) }
                .overlay { shimmer(driftX: driftX, driftY: driftY).allowsHitTesting(false) }
        }
    }

    /// The deliberate Liquid Glass abuse: a full-cover clear-glass lens (macOS 26) or frosted material
    /// (macOS 15) that refracts the whole popover.
    @ViewBuilder
    private func glassLens() -> some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    /// Rotating pink iridescence, blended so it tints and washes the content rather than hiding it flat.
    private func pinkWash(angle: Double) -> some View {
        AngularGradient(colors: discoColors, center: .center, angle: .degrees(angle))
            .blendMode(.overlay)
            .opacity(0.95)
    }

    /// A soft white specular highlight that drifts around — the "liquid" shimmer of the glass.
    private func shimmer(driftX: Double, driftY: Double) -> some View {
        RadialGradient(
            colors: [Color.white.opacity(0.55), .clear],
            center: UnitPoint(x: 0.5 + driftX, y: 0.5 + driftY),
            startRadius: 0,
            endRadius: 130
        )
        .blendMode(.plusLighter)
    }
}
