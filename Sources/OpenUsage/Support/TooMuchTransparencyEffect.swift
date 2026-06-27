import SwiftUI

extension View {
    /// The "too much transparency" easter-egg treatment for the ghost styles: an animated pink/rose
    /// iridescence that slowly rotates over a clear Liquid Glass lens, a soft specular shimmer that
    /// drifts around, and the content gently blurred, breathing, and swaying. The result is barely
    /// readable, but on purpose and in a pretty, chaotic-but-elegant way — the joke leans into abusing
    /// Liquid Glass, not just cranking the window alpha. A no-op for the non-egg styles.
    @ViewBuilder
    func tooMuchTransparency(_ style: PopoverTransparencyStyle) -> some View {
        switch style {
        case .ghost:
            modifier(TooMuchTransparencyModifier(intense: false))
        case .ghostMore:
            modifier(TooMuchTransparencyModifier(intense: true))
        case .opaque, .increased:
            self
        }
    }
}

/// Drives every animated value off one continuous clock (`TimelineView(.animation)`) so the motion is
/// smooth and self-contained — the modifier is only mounted while the egg is on, so there's no cost
/// otherwise. `intense` is the "Even More" gear: faster, blurrier, more saturated, more pink.
private struct TooMuchTransparencyModifier: ViewModifier {
    let intense: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let spin = t * (intense ? 26 : 14)                       // gradient rotation, degrees/sec
            let hueWobble = sin(t * (intense ? 1.1 : 0.7)) * (intense ? 16 : 9)
            let sway = sin(t * (intense ? 1.5 : 0.9)) * (intense ? 1.1 : 0.6)   // degrees
            let breathe = 1 + sin(t * (intense ? 1.2 : 0.8)) * (intense ? 0.018 : 0.01)
            let driftX = cos(t * (intense ? 0.8 : 0.5)) * 0.32       // shimmer drift, unit-point offset
            let driftY = sin(t * (intense ? 0.9 : 0.6)) * 0.32

            content
                .saturation(intense ? 1.55 : 1.2)
                .blur(radius: intense ? 3.6 : 2.2)
                .hueRotation(.degrees(hueWobble))
                // Over-scale so the sway never opens a gap at the rounded corners; the host clips it.
                .scaleEffect((intense ? 1.05 : 1.035) * breathe)
                .rotationEffect(.degrees(sway))
                .overlay { glassLens().allowsHitTesting(false) }
                .overlay { pinkWash(angle: spin).allowsHitTesting(false) }
                .overlay { shimmer(driftX: driftX, driftY: driftY).allowsHitTesting(false) }
        }
    }

    /// The deliberate Liquid Glass abuse: a full-cover clear-glass lens that refracts and frosts the
    /// whole popover (macOS 26), or a frosted material on macOS 15.
    @ViewBuilder
    private func glassLens() -> some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    /// The rotating pink iridescence, blended so it tints and washes the content rather than hiding it.
    private func pinkWash(angle: Double) -> some View {
        AngularGradient(
            colors: [
                Color(red: 1.00, green: 0.42, blue: 0.78),
                Color(red: 0.96, green: 0.28, blue: 0.62),
                Color(red: 0.80, green: 0.40, blue: 0.96),
                Color(red: 1.00, green: 0.58, blue: 0.86),
                Color(red: 1.00, green: 0.42, blue: 0.78),
            ],
            center: .center,
            angle: .degrees(angle)
        )
        .blendMode(.overlay)
        .opacity(intense ? 0.95 : 0.72)
    }

    /// A soft white specular highlight that drifts around — the "liquid" shimmer of the glass.
    private func shimmer(driftX: Double, driftY: Double) -> some View {
        RadialGradient(
            colors: [Color.white.opacity(intense ? 0.55 : 0.4), .clear],
            center: UnitPoint(x: 0.5 + driftX, y: 0.5 + driftY),
            startRadius: 0,
            endRadius: intense ? 130 : 170
        )
        .blendMode(.plusLighter)
    }
}
