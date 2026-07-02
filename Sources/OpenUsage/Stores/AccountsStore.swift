import Foundation
import Observation

/// Persisted list of extra provider accounts (beyond the default CLI login). The provider list is
/// built from this at launch, so changes take effect on the next app start (matching how adding a
/// CLI account works). The Accounts settings tab drives it.
@MainActor
@Observable
final class AccountsStore {
    private static let storageKey = "openusage.extraAccounts.v1"

    private(set) var accounts: [ExtraAccount]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ExtraAccount].self, from: data) {
            self.accounts = decoded
        } else {
            self.accounts = []
        }
    }

    func add(_ account: ExtraAccount) {
        accounts.removeAll { $0.instanceID == account.instanceID }
        accounts.append(account)
        persist()
    }

    func remove(instanceID: String) {
        accounts.removeAll { $0.instanceID == instanceID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else {
            AppLog.error(.config, "failed to encode extra accounts")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
