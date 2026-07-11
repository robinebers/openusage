import AppKit

/// Explicit appearance override for the whole app; `.system` follows macOS. Applied as
/// `NSApp.appearance` — the panel hosting ignores SwiftUI's `preferredColorScheme`, so the override
/// has to happen at the AppKit level. `applyCurrent()` also posts `didChangeNotification` for
/// `StatusItemController` to pin the same appearance directly on the menu-bar panel. The menu-bar
/// label is unaffected (template image).
enum AppearanceSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case system
    case light
    case dark

    static let key = "appearance"
    static var fallback: AppearanceSetting { .system }

    /// Posted by `applyCurrent()` after the app-level appearance is set, so the popover owner can
    /// mirror the override onto the menu-bar panel.
    static let didChangeNotification = Notification.Name("AppearanceSettingDidChange")

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` for `.system`: both `NSApp` and the menu-bar panel inherit the OS setting, so "System"
    /// tracks live theme switches without re-applying.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    // `current` (the stored choice, `.system` when unset) comes from `UserDefaultsBacked`.

    /// Reads the stored choice and applies it app-wide. Call once at launch and again whenever
    /// the setting changes — app windows restyle immediately, and the notification lets the
    /// status-item owner restyle the menu-bar panel.
    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
