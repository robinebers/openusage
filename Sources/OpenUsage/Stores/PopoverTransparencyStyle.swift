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
    /// disco meters, all behind crisp text on frosted cards.
    case disco
    /// Secret-code egg + "Even More": the deliberately barely-readable pink-glass chaos.
    case ghost

    /// How the page tray and cards paint their base.
    var surfaceTreatment: PopoverSurfaceTreatment {
        switch self {
        case .opaque: return .opaque
        case .increased, .ghost: return .translucent   // clear, so the desktop/chaos shows through
        case .disco: return .scrim                      // frosted cards keep text readable over the party
        }
    }

    /// Window-level alpha. The proper and disco modes stay (near) solid so text is crisp; only the ghost
    /// fades the whole window — text and all — into a see-through gimmick. (Tunable; verified live.)
    var windowAlpha: CGFloat {
        switch self {
        case .opaque, .increased: return 1
        case .disco: return 0.94
        case .ghost: return 0.62
        }
    }

    /// The window shadow reads as a hard rectangle once the surface is a faint ghost, so drop it there.
    var wantsShadow: Bool {
        switch self {
        case .opaque, .increased, .disco: return true
        case .ghost: return false
        }
    }

    /// The single home for the precedence rules. The egg wins regardless of the system accessibility
    /// flags (it's an opt-in cheat code the user explicitly invoked): the secret code turns on the
    /// readable disco, and "Even More" pushes it to the unreadable ghost. The proper "Increase
    /// Transparency" toggle yields to the system's Reduce Transparency / Increase Contrast settings.
    static func resolve(
        increaseTransparency: Bool,
        secretCodeActive: Bool,
        evenMore: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PopoverTransparencyStyle {
        if secretCodeActive {
            return evenMore ? .ghost : .disco
        }
        if increaseTransparency, !reduceTransparency, !increaseContrast {
            return .increased
        }
        return .opaque
    }
}
