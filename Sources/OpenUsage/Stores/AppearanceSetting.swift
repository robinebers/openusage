import AppKit

/// Explicit appearance override for the whole app; `.system` follows macOS. Applied as
/// `NSApp.appearance` — the panel hosting ignores SwiftUI's `preferredColorScheme`, so the override
/// has to happen at the AppKit level, and the menu-bar panel inherits it. The menu-bar label is
/// unaffected (template image).
enum AppearanceSetting: String, Hashable, Sendable, CaseIterable {
    case system
    case light
    case dark

    static let key = "appearance"

    static var current: AppearanceSetting { UserDefaults.standard.enumValue(forKey: key, default: .system) }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
    }
}
