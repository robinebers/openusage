import Foundation
import Observation

/// User-chosen display names for accounts, keyed by the account's email (not the config slot or
/// whether it's the default login). Keying by email means a name follows the account to whichever card
/// shows it — important because the Claude CLI's "default" login flip-flops between accounts.
@MainActor
@Observable
final class AccountNamesStore {
    private static let storageKey = "openusage.accountNames.v1"

    private(set) var names: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.names = (defaults.dictionary(forKey: Self.storageKey) as? [String: String]) ?? [:]
    }

    /// The custom name for an email, or nil if none is set.
    func name(for email: String?) -> String? {
        guard let email, let name = names[email.lowercased()], !name.isEmpty else { return nil }
        return name
    }

    /// Set (or clear, when blank) the custom name for an email.
    func setName(_ name: String, for email: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = email.lowercased()
        if trimmed.isEmpty {
            names.removeValue(forKey: key)
        } else {
            names[key] = trimmed
        }
        defaults.set(names, forKey: Self.storageKey)
    }
}
