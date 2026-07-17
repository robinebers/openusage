import SwiftUI

/// True inside the readable "party" easter-egg mode, so leaf views (meter bars, provider marks) can
/// join the party while staying legible. Default `false` everywhere — the windowless ShareCard export
/// and every normal surface never opt in. (The unreadable "drunk" escalation does not set this; it just
/// blurs everything.)
private struct PopoverPartyModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverPartyMode: Bool {
        get { self[PopoverPartyModeKey.self] }
        set { self[PopoverPartyModeKey.self] = newValue }
    }
}

/// Whether the hosting popover is currently on-screen. The easter-egg animation loops read this to
/// **mount** their `TimelineView(.animation)` clocks only while the popover is visible and motion is
/// allowed, and drop to a static frame otherwise. A closed popover or reduced-motion preference with
/// the egg still active therefore runs no display link and spends no animation work. Default `false`,
/// so the windowless ShareCard export and any non-popover host never mount the loops. Seeded from
/// `PopoverTransparencyStore.popoverShown`, which `StatusItemController` flips at its
/// `showPanel`/`hidePanel` chokepoints.
///
/// This is a STRUCTURAL mount gate (`if shown { TimelineView } else { static }`), deliberately NOT the
/// reverted `TimelineView(.animation(paused: !shown))` overload (commit 1ef9c4e): that overload froze
/// in-place activation because its schedule only re-primes on a window-lifecycle event, never on an
/// in-place `paused` flip. Mounting a fresh `TimelineView` always attaches its display link, so the egg
/// starts the instant it's switched on with the popover already open. Do not collapse this back to the
/// paused overload.
private struct PopoverIsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverIsVisible: Bool {
        get { self[PopoverIsVisibleKey.self] }
        set { self[PopoverIsVisibleKey.self] = newValue }
    }
}

/// Renders time-driven `content(t)` under a live `TimelineView(.animation)` while the popover is
/// on-screen and motion is allowed, and at a single static frame otherwise — so no display link ticks
/// behind a closed popover or under Reduce Animations, yet the look doesn't disappear. Reduced motion
/// uses the calm baseline (`t == 0`); a merely hidden popover keeps its current-looking phase. This is
/// the shared home of the STRUCTURAL mount gate every easter-egg loop uses; it is
/// deliberately NOT the reverted `TimelineView(.animation(paused:))` overload (see `\.popoverIsVisible`).
/// Both branches carry `.transition(.identity)` so toggling the egg crossfades via the surrounding
/// `.animation`, never a hard cut. `t` is `timeIntervalSinceReferenceDate`.
struct VisibilityGatedTimeline<Content: View>: View {
    @Environment(\.popoverIsVisible) private var shown
    @Environment(\.reduceAnimations) private var reduceAnimations
    private let content: (TimeInterval) -> Content

    init(@ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.content = content
    }

    var body: some View {
        switch MotionTimelineMode.resolve(popoverShown: shown, reduceAnimations: reduceAnimations) {
        case .live:
            TimelineView(.animation) { timeline in
                content(timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        case .currentStatic:
            content(Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        case .baselineStatic:
            content(0)
                .transition(.identity)
        }
    }
}

/// Structural policy for continuous decorative motion. Kept pure so the no-display-link guarantee is
/// regression-testable without mounting a SwiftUI host.
enum MotionTimelineMode: Equatable {
    case live
    case currentStatic
    case baselineStatic

    static func resolve(popoverShown: Bool, reduceAnimations: Bool) -> Self {
        if reduceAnimations { return .baselineStatic }
        return popoverShown ? .live : .currentStatic
    }
}

enum PartyMode {
    /// Vivid gradient fill for meter bars in party mode. The bar still shows its fraction by width, so
    /// it stays readable — it just trades the solid severity color for party colors.
    static let meterFill = AnyShapeStyle(
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.35, blue: 0.78),
                Color(red: 0.60, green: 0.42, blue: 1.00),
                Color(red: 0.30, green: 0.85, blue: 1.00),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    )
}

extension View {
    /// A gentle pulse + color shimmer for the provider marks while party mode is on; identity otherwise
    /// (no `TimelineView` mounted when the party is off).
    @ViewBuilder
    func partyPulse(_ active: Bool) -> some View {
        if active {
            modifier(PartyPulseModifier())
        } else {
            self
        }
    }
}

private struct PartyPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Clock mounts only while the popover is on-screen (see `VisibilityGatedTimeline`); the pulse
        // starts immediately on reopen / in-place activation and costs nothing when the popover is closed.
        VisibilityGatedTimeline { t in pulse(content, at: t) }
    }

    private func pulse(_ content: Content, at t: TimeInterval) -> some View {
        content
            .scaleEffect(1 + sin(t * 3.2) * 0.12)
            .hueRotation(.degrees(sin(t * 2.0) * 28))
    }
}
