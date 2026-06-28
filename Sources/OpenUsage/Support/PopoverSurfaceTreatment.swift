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
    /// The page clears to whatever is behind the window (the behind-window vibrancy desktop, the party
    /// tint over it, or the drunk haze); cards drop their opaque base for a frosted `.regularMaterial`
    /// so text stays legible over it — the HIG-correct "translucent but legible" content material, not a
    /// bare fill. Shared by Increase Transparency, party, and drunk.
    case translucent
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
