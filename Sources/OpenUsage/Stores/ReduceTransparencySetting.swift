import Foundation

/// Opt-in switch that drops the popover's Liquid Glass for a solid, higher-contrast surface — the
/// fix for "I can't read it over a busy desktop" without taking glass away from everyone (it's off
/// by default). Stored as a plain `Bool` under one `UserDefaults.standard` key, so it doesn't need
/// the `UserDefaultsBacked` enum machinery; this namespace just holds the key and a live reader.
///
/// The app toggle is OR'd with macOS's own *Reduce Transparency* accessibility setting at the view
/// layer (`DashboardView`), so a user who has the system setting on gets the solid surface even if
/// they never touch this toggle.
enum ReduceTransparencySetting {
    /// The `UserDefaults.standard` key this setting persists under.
    static let key = "reduceTransparency"

    /// Posted when the in-app toggle flips, so the panel's AppKit glass backdrop
    /// (`StatusItemController`) can swap to a solid surface live — `@AppStorage` reactivity only
    /// re-renders the in-window content, not the window's own backdrop. Mirrors
    /// `AppearanceSetting.didChangeNotification`. (macOS's *own* Reduce Transparency setting is
    /// observed separately, via `NSWorkspace`.)
    static let didChangeNotification = Notification.Name("ReduceTransparencySettingDidChange")

    /// The stored choice, read live from `UserDefaults.standard` (defaults to `false` when unset —
    /// a missing bool key reads as `false`, which is exactly the "glass on" default we want).
    static var current: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
