import AppKit

/// Explicit appearance override for the whole app; `.system` follows macOS. Applied as
/// `NSApp.appearance` — the popover hosting ignores SwiftUI's `preferredColorScheme`, so the
/// override has to happen at the AppKit level. The menu-bar popover does not even inherit
/// `NSApp.appearance` (an `NSPopover` follows its positioning view, the status-bar button), so
/// `applyCurrent()` also posts `didChangeNotification` for `StatusItemController` to restyle the
/// popover directly. The menu-bar label is unaffected (template image).
enum AppearanceSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case system
    case light
    case dark

    static let key = "appearance"
    static var fallback: AppearanceSetting { .system }

    /// Posted by `applyCurrent()` after the app-level appearance is set, so the popover owner can
    /// mirror the override onto the popover (which does not inherit `NSApp.appearance`).
    static let didChangeNotification = Notification.Name("AppearanceSettingDidChange")

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` for `.system`: an unset appearance inherits — `NSApp` from the OS setting, the
    /// popover from the menu bar — so "System" tracks live theme switches without re-applying.
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
    /// status-item owner restyle the popover (which inherits from the menu bar, not the app).
    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
