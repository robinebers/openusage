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
        // Plain `.animation` (not the `paused:` overload), so it starts immediately when party is switched
        // on with the popover already open — the visibility-coupled overload only attached on a window
        // show, which froze in-place activation until a close→reopen.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            content
                .scaleEffect(1 + sin(t * 3.2) * 0.12)
                .hueRotation(.degrees(sin(t * 2.0) * 28))
        }
    }
}
