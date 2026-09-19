import Foundation

/// Whether the app masks email addresses wherever it shows an account (Settings → Privacy). Off by
/// default. Multi-account providers are named after their accounts, so an email can appear in card
/// headers, Customize, the Total Spend legend, menus, notifications, and exported share cards; every
/// one of those reads the provider's name through `Provider.visibleName(hidingEmails:)` or
/// `Provider.headerName(hidingAgentName:hidingEmails:)`. Machine-readable surfaces (the local API,
/// the CLI, logs) keep real addresses, since tools that read them match on identity.
enum HideEmailsSetting {
    static let key = "hideAccountEmails"
    static let fallback = false

    /// Live value for call sites outside the SwiftUI tree: notifications and the menu bar's
    /// VoiceOver summary.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key, default: fallback)
    }
}
