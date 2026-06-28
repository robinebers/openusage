import CoreGraphics

/// The popover's resolved transparency level. Deliberately discrete (not a continuous slider) so the
/// precedence rules, the accessibility clamp, and the visual-regression tests stay tractable; a future
/// level is one more case here.
enum PopoverTransparencyStyle: Equatable, Sendable {
    /// Today's solid, opaque panel.
    case opaque
    /// The proper "Increase Transparency": the desktop shows through with system vibrancy, text legible.
    case increased
    /// Secret-code easter egg: a loud but **readable** party built on the same translucent foundation as
    /// `increased` — the blurred desktop shows through, tinted by an animated party gradient, with a
    /// glowing rim, party meters, and crisp text on frosted cards on top.
    case party
    /// Party + "Drunk Mode": woozy and deliberately barely-readable — blur, pink haze, a spinning sway.
    case drunk

    /// How the page tray and cards paint their base.
    var surfaceTreatment: PopoverSurfaceTreatment {
        switch self {
        case .opaque: return .opaque
        // All three translucent modes clear the page so the behind-window vibrancy backdrop (the
        // blurred desktop) shows through; party tints that same backdrop rather than replacing it.
        case .increased, .party, .drunk: return .translucent
        }
    }

    /// Window-level alpha. Opaque, increased, and party all keep the window fully opaque — the desktop
    /// shows through via the translucent backdrop, never by fading the window (fading would dim the text
    /// too). Only drunk deliberately fades the whole window — text and all — into a see-through haze.
    /// (Tunable; verified live.)
    var windowAlpha: CGFloat {
        switch self {
        case .opaque, .increased, .party: return 1
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

    /// The single home for the precedence rules. Reduce Transparency and Increase Contrast are
    /// accessibility *needs*, not preferences, so they clamp everything to opaque first — neither the
    /// opt-in "Increase Transparency" toggle nor the secret-code egg may turn the panel translucent or
    /// fade the window while either is on. The egg being a hidden, user-invoked cheat code doesn't make
    /// overriding an accessibility setting safe, so it yields too. With the flags off the egg wins (the
    /// secret code is the readable party, "Drunk Mode" the woozy barely-readable drunk), then the proper
    /// toggle, then opaque.
    static func resolve(
        increaseTransparency: Bool,
        secretCodeActive: Bool,
        drunkMode: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PopoverTransparencyStyle {
        // Accessibility wins over every translucent treatment, the egg included.
        if reduceTransparency || increaseContrast {
            return .opaque
        }
        if secretCodeActive {
            return drunkMode ? .drunk : .party
        }
        if increaseTransparency {
            return .increased
        }
        return .opaque
    }
}
