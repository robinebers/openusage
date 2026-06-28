import SwiftUI

/// How the popover's page tray and grouped cards paint their base.
///
/// `.opaque` is the default and keeps today's solid panel (and the windowless `ShareCardView`
/// `ImageRenderer` export, which never injects a non-default value). `.translucent` clears the opaque
/// page base so the AppKit behind-window vibrancy backdrop — the desktop — shows through. The value is
/// driven from `PopoverTransparencyStore.surfaceTreatment` and read by `PopoverSurface` (the tray) and
/// `CardSurfaceModifier` (the grouped cards).
enum PopoverSurfaceTreatment: Equatable, Sendable {
    /// Today's solid panel: opaque tray, opaque card base.
    case opaque
    /// The page clears to whatever is behind the window (vibrancy desktop, or the ghost chaos); cards
    /// clear their opaque base too.
    case translucent
    /// Disco: the page clears so the animated party backdrop shows, but cards keep a frosted material
    /// base so the text on them stays readable over the moving colors.
    case scrim
}

private struct PopoverSurfaceTreatmentKey: EnvironmentKey {
    static let defaultValue: PopoverSurfaceTreatment = .opaque
}

extension EnvironmentValues {
    var popoverSurfaceTreatment: PopoverSurfaceTreatment {
        get { self[PopoverSurfaceTreatmentKey.self] }
        set { self[PopoverSurfaceTreatmentKey.self] = newValue }
    }
}
