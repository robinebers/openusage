import Foundation
import Observation

/// Masks presentation only. Accounts, credentials, provider requests and CLI output keep their data.
@MainActor
@Observable
final class PrivacyModeSetting {
    static let key = "privacyModeEnabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.key)
            didChange?()
        }
    }

    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key)
    }

    static func accountName(_ provider: Provider, isEnabled: Bool) -> String {
        isEnabled ? "Hidden Account" : provider.accountName
    }

    static func fullName(_ provider: Provider, isEnabled: Bool) -> String {
        isEnabled ? "\(provider.displayName) · Hidden Account" : provider.fullName
    }

    static func host(_ host: String, isEnabled: Bool) -> String {
        isEnabled ? "Hidden Hub" : host
    }

    static func message(_ message: String, isEnabled: Bool) -> String {
        isEnabled ? "Details are hidden while Privacy Mode is on." : message
    }

    static func badge(_ badge: String?, isEnabled: Bool) -> String? {
        isEnabled ? badge.map { _ in "•" } : badge
    }

    /// Used for menu-bar rendering, without changing the registry or the account's API actions.
    static func provider(_ provider: Provider, isEnabled: Bool) -> Provider {
        guard isEnabled else { return provider }
        var masked = provider
        masked.accountLabel = accountName(provider, isEnabled: true)
        masked.badge = badge(provider.badge, isEnabled: true)
        masked.organization = nil
        masked.hubHost = provider.hubHost.map { host($0, isEnabled: true) }
        return masked
    }
}
