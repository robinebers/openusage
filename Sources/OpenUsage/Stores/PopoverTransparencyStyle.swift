import CoreGraphics

/// The popover's resolved transparency level. Deliberately discrete (not a continuous slider) so the
/// precedence rules, the accessibility clamp, and the visual-regression tests stay tractable; a future
/// level is one more case here.
enum PopoverTransparencyStyle: Equatable, Sendable {
    /// Today's solid, opaque panel.
    case opaque
    /// The proper "Increase Transparency": the desktop shows through with system vibrancy, text legible.
    case increased
    /// Secret-code easter egg: a loud but **readable** party — animated gradient backdrop, glowing rim,
    /// party meters, all behind crisp text on frosted cards.
    case party
    /// Party + "Drunk Mode": woozy and deliberately barely-readable — blur, pink haze, a spinning sway.
    case drunk

    /// How the page tray and cards paint their base.
    var surfaceTreatment: PopoverSurfaceTreatment {
        switch self {
        case .opaque: return .opaque
        case .increased, .drunk: return .translucent   // clear, so the desktop/haze shows through
        case .party: return .scrim                      // frosted cards keep text readable over the party
        }
    }

    /// Window-level alpha. The proper and party modes stay (near) solid so text is crisp; only drunk
    /// fades the whole window — text and all — into a see-through haze. (Tunable; verified live.)
    var windowAlpha: CGFloat {
        switch self {
        case .opaque, .increased: return 1
        case .party: return 0.94
        case .drunk: return 0.62
        }
    }

    /// The window shadow reads as a hard rectangle once the surface is a faint haze, so drop it there.
    var wantsShadow: Bool {
        switch self {
        case .opaque, .increased, .party: return true
        case .drunk: return false
        }
    }

    /// The single home for the precedence rules. The egg wins regardless of the system accessibility
    /// flags (it's an opt-in cheat code the user explicitly invoked): the secret code turns on the
    /// readable party, and "Drunk Mode" pushes it to the woozy, barely-readable drunk. The proper
    /// "Increase Transparency" toggle yields to the system's Reduce Transparency / Increase Contrast.
    static func resolve(
        increaseTransparency: Bool,
        secretCodeActive: Bool,
        drunkMode: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PopoverTransparencyStyle {
        if secretCodeActive {
            return drunkMode ? .drunk : .party
        }
        if increaseTransparency, !reduceTransparency, !increaseContrast {
            return .increased
        }
        return .opaque
    }
}
