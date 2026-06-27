import CoreGraphics

/// The popover's resolved transparency level. Deliberately discrete (not a continuous slider) so the
/// precedence rules, the accessibility clamp, and the visual-regression tests stay tractable; a future
/// level is one more case here. Cases are ordered by increasing transparency.
enum PopoverTransparencyStyle: Equatable, Sendable {
    /// Today's solid, opaque panel.
    case opaque
    /// The proper "Increase Transparency": the desktop shows through with system vibrancy, text legible.
    case increased
    /// Secret-code easter egg: a barely-readable ghost.
    case ghost
    /// Secret-code easter egg + "Even More": ghostier still.
    case ghostMore

    /// Whether the page tray and cards should clear their opaque base so the behind-window vibrancy
    /// backdrop (the desktop) shows through.
    var surfaceTreatment: PopoverSurfaceTreatment {
        self == .opaque ? .opaque : .translucent
    }

    /// Window-level alpha. The proper modes keep full opacity so text stays legible. The egg modes stay
    /// only partly transparent on purpose: the "barely readable" look comes from the animated pink-glass
    /// chaos (`tooMuchTransparency`), not from fading the window to nothing — too low an alpha would dim
    /// the pink along with everything else. (Tunable; verified live since there's no preview.)
    var windowAlpha: CGFloat {
        switch self {
        case .opaque, .increased: return 1
        case .ghost: return 0.8
        case .ghostMore: return 0.65
        }
    }

    /// The window shadow reads as a hard rectangle once the surface is a faint ghost, so drop it there.
    var wantsShadow: Bool {
        switch self {
        case .opaque, .increased: return true
        case .ghost, .ghostMore: return false
        }
    }

    /// The single home for the precedence rules. The egg wins regardless of the system accessibility
    /// flags (it's an opt-in cheat code the user explicitly invoked); the proper "Increase Transparency"
    /// toggle yields to the system's Reduce Transparency / Increase Contrast settings.
    static func resolve(
        increaseTransparency: Bool,
        secretCodeActive: Bool,
        evenMore: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PopoverTransparencyStyle {
        if secretCodeActive {
            return evenMore ? .ghostMore : .ghost
        }
        if increaseTransparency, !reduceTransparency, !increaseContrast {
            return .increased
        }
        return .opaque
    }
}
