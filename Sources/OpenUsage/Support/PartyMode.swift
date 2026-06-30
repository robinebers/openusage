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
/// **mount** their `TimelineView(.animation)` clocks only while the popover is visible and drop to a
/// static frame when it isn't, so a closed popover with the egg still active runs no display link and
/// spends no CPU. Default `false`, so the windowless ShareCard export and any non-popover host never
/// mount the loops. Seeded from `PopoverTransparencyStore.popoverShown`, which `StatusItemController`
/// flips at its `showPanel`/`hidePanel` chokepoints.
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
    @Environment(\.popoverIsVisible) private var shown

    @ViewBuilder
    func body(content: Content) -> some View {
        // Mount the pulse clock only while the popover is on-screen; a closed popover with the egg still
        // active drops to a static frame (no `TimelineView`, no display link, no CPU). A fresh mount on
        // reopen / in-place activation always attaches its display link, so the pulse starts immediately —
        // unlike the reverted `.animation(paused:)` overload (see `\.popoverIsVisible`).
        if shown {
            TimelineView(.animation) { timeline in
                pulse(content, at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else {
            // Frozen at the current instant so it matches the live clock's first frame (no scale pop).
            pulse(content, at: Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        }
    }

    private func pulse(_ content: Content, at t: TimeInterval) -> some View {
        content
            .scaleEffect(1 + sin(t * 3.2) * 0.12)
            .hueRotation(.degrees(sin(t * 2.0) * 28))
    }
}
