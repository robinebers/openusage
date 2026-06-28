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

/// Whether the popover is currently on-screen. The easter-egg animations pause their `TimelineView`
/// clocks when this is `false`, so a closed (but still-egg-active) popover spends no CPU animating — the
/// SwiftUI tree survives `orderOut`, so without this the loops would keep ticking while hidden. Driven
/// from `DashboardView`'s `PopoverVisibilityReader`. Defaults to `false` (paused) so nothing animates
/// until the popover reports itself visible.
private struct PopoverIsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverIsVisible: Bool {
        get { self[PopoverIsVisibleKey.self] }
        set { self[PopoverIsVisibleKey.self] = newValue }
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
    @Environment(\.popoverIsVisible) private var isVisible

    func body(content: Content) -> some View {
        // Runs at the display's native rate (matching the user's refresh, including ProMotion) while the
        // popover is on-screen, and pauses entirely when it isn't — so a hidden popover spends no energy.
        TimelineView(.animation(paused: !isVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            content
                .scaleEffect(1 + sin(t * 3.2) * 0.12)
                .hueRotation(.degrees(sin(t * 2.0) * 28))
        }
    }
}
