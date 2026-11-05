import Foundation
import Observation

@MainActor
@Observable
final class AccountStore {
    static let storageKey = "accounts.v1"
    static let hubsStorageKey = "cliproxyHubs.v1"

    private(set) var accounts: [Account]
    private(set) var hubs: [CLIProxyHub]
    private(set) var lastError: String?
    @ObservationIgnored var didChange: (() -> Void)?
    /// The stored entries this build cannot decode, as JSON values. Saving writes them back after the
    /// accounts, so a build that reads them still finds them.
    @ObservationIgnored private var unreadableEntries: [Any]
    private let defaults: UserDefaults
    let credentialVault: any CredentialVault
    let hubKeys: any HubKeyVault
    @ObservationIgnored private let makeID: () -> UUID
    /// The hub accounts whose logins the last listing of their hub lacked.
    @ObservationIgnored private var unlistedHubAccounts: Set<UUID> = []

    init(
        defaults: UserDefaults = .standard,
        vault: any CredentialVault = KeychainCredentialVault(),
        hubKeys: any HubKeyVault = KeychainHubKeyVault(),
        makeID: @escaping () -> UUID = { UUID() }
    ) {
        self.defaults = defaults
        credentialVault = vault
        self.hubKeys = hubKeys
        self.makeID = makeID
        let stored = Self.load(from: defaults)
        accounts = stored.accounts.map { account in
            var named = account
            named.label = Self.name(account.label, for: account.kind)
            return named
        }
        unreadableEntries = stored.unreadableEntries
        hubs = defaults.data(forKey: Self.hubsStorageKey).flatMap { data in
            do {
                return try JSONDecoder().decode([CLIProxyHub].self, from: data)
            } catch {
                AppLog.error(LogTag.auth("cliproxy"), "cannot read the stored hub list: \(error)")
                return nil
            }
        } ?? []
        let renamed = zip(stored.accounts, accounts).filter { $0.label != $1.label }
        if !renamed.isEmpty {
            AppLog.info(LogTag.auth("accounts"), "named \(renamed.map(\.1.cardID).joined(separator: ", ")), which had no name the dashboard shows")
            persist()
        }
    }

    /// The dashboard leaves out a name that only repeats the provider's, so a blank name or the provider's
    /// own becomes the provider's default account name.
    static func name(_ label: String, for kind: ProviderKind) -> String {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.caseInsensitiveCompare(kind.displayName) == .orderedSame ? "\(kind.displayName) Account" : name
    }

    static func load(from defaults: UserDefaults) -> (accounts: [Account], unreadableEntries: [Any]) {
        guard let data = defaults.data(forKey: storageKey) else { return ([], []) }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            AppLog.error(LogTag.auth("accounts"), "cannot read the stored account list, which is not a JSON array")
            return ([], [])
        }
        var accounts: [Account] = []
        var unreadableEntries: [Any] = []
        for (index, entry) in entries.enumerated() {
            do {
                let entryData = try JSONSerialization.data(withJSONObject: entry, options: .fragmentsAllowed)
                accounts.append(try JSONDecoder().decode(Account.self, from: entryData))
            } catch {
                AppLog.error(LogTag.auth("accounts"), "cannot read stored account entry \(index), keeping it unchanged: \(error)")
                unreadableEntries.append(entry)
            }
        }
        return (accounts.sorted { $0.addedAt < $1.addedAt }, unreadableEntries)
    }

    @discardableResult
    func add(kind: ProviderKind, label: String, organization: String? = nil, domain: String? = nil, credential: AccountCredential) -> Account {
        let account = newAccount(kind: kind, label: label, organization: organization, domain: domain)
        do {
            try credentialVault.save(credential, for: account.id)
            accounts.append(account)
            persist()
            didChange?()
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("accounts"), "could not save account: \(error.localizedDescription)")
        }
        return account
    }

    func rename(_ id: UUID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = Self.name(label, for: accounts[index].kind)
        persist()
        didChange?()
    }

    func remove(_ id: UUID) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == id }) else { return }
        do {
            try credentialVault.delete(id)
            accounts.remove(at: accountIndex)
            persist()
            didChange?()
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("accounts"), "could not remove account credential: \(error.localizedDescription)")
        }
    }

    /// Writes on the main actor, as `add` and `remove` do, so a removal can never fall between the
    /// check that the account is still added and the write. It saves rather than updates: a pasted key
    /// is the whole credential, so it also restores an account whose Keychain item has gone missing.
    func replaceCredential(_ credential: AccountCredential, for id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        try checkForDuplicate(credential, kind: account.kind, organization: account.organization, excluding: id)
        try credentialVault.save(credential, for: id)
    }

    func credential(for id: UUID) throws -> AccountCredential? {
        try credentialVault.load(id)
    }

    /// Matches a direct sign-in by organization or credential identity. A missing Keychain item
    /// cannot match, but an unreadable one cannot establish that the sign-in is distinct.
    func checkForDuplicate(_ credential: AccountCredential, kind: ProviderKind, organization: String?, excluding id: UUID? = nil) throws {
        let identity = credential.identity
        for account in accounts where account.kind == kind && account.hub == nil && account.id != id {
            if let organization {
                guard account.organization?.caseInsensitiveCompare(organization) == .orderedSame else { continue }
            } else {
                guard account.organization == nil else { continue }
                guard let identity else { return }
                do {
                    guard try credentialVault.load(account.id)?.identity == identity else { continue }
                } catch {
                    AppLog.error(.auth, "\(account.cardID) could not check its Keychain item for a duplicate sign-in: \(error.localizedDescription)")
                    throw ProviderError.unavailable("OpenUsage couldn't check the saved sign-in for \(account.label). Check Keychain access and try again.")
                }
            }
            throw ProviderError.unavailable("This account is already added as \(account.label).")
        }
    }

    func account(cardID: String) -> Account? {
        accounts.first { $0.cardID == cardID }
    }

    func accounts(onHub hubID: UUID) -> [Account] {
        accounts.filter { $0.hub?.hubID == hubID }
    }

    /// Saves a newly connected hub and its management key, bound to the hub's address. Its logins arrive with `mirror`.
    func addHub(_ hub: CLIProxyHub, key: String) throws {
        try hubKeys.save(HubKey(key: key, url: hub.url), for: hub.id)
        hubs.append(hub)
        persistHubs()
    }

    func replaceHubKey(_ key: String, for hubID: UUID) throws {
        guard let hub = hubs.first(where: { $0.id == hubID }) else { return }
        try hubKeys.save(HubKey(key: key, url: hub.url), for: hubID)
    }

    /// Removes a hub together with every account mirrored from it and its management key.
    func removeHub(_ hubID: UUID) {
        let mirrored = Set(accounts(onHub: hubID).map(\.id))
        do {
            for id in mirrored { try credentialVault.delete(id) }
            try hubKeys.delete(hubID)
        } catch {
            lastError = error.localizedDescription
            return AppLog.error(LogTag.auth("cliproxy"), "could not remove a hub's credentials: \(error.localizedDescription)")
        }
        accounts.removeAll { mirrored.contains($0.id) }
        hubs.removeAll { $0.id == hubID }
        persistHubs()
        persist()
        didChange?()
    }

    /// Makes the hub's mirrored accounts match its login list: a new login is added at the bottom of its
    /// provider's accounts, a login disabled on the hub is removed, a login gone from the hub is removed
    /// once two listings in a row lack it, and a renamed one, or one switched to another ChatGPT workspace,
    /// is relinked. The same listing applied twice changes nothing the second time. Throws when a Keychain
    /// write fails, after applying the rest.
    func mirror(_ logins: [HubLogin], from hubID: UUID) throws {
        guard let hub = hubs.first(where: { $0.id == hubID }) else { return }
        let plan = HubReconciliation(hub: hub, logins: logins, accounts: accounts, missingBefore: unlistedHubAccounts)
        unlistedHubAccounts.subtract(accounts(onHub: hubID).map(\.id))
        unlistedHubAccounts.formUnion(plan.missing)
        guard !plan.isEmpty else { return }
        var failures: [any Error] = []
        var removed = Set<UUID>()
        for id in plan.removed {
            do {
                try credentialVault.delete(id)
                removed.insert(id)
            } catch {
                failures.append(error)
            }
        }
        accounts.removeAll { removed.contains($0.id) }
        unlistedHubAccounts.formUnion(Set(plan.removed).subtracting(removed))
        for index in accounts.indices {
            guard let link = plan.relinked[accounts[index].id] else { continue }
            do {
                if link.chatGPTAccountID != accounts[index].hub?.chatGPTAccountID { try credentialVault.save(link.credential, for: accounts[index].id) }
                accounts[index].hub = link
            } catch {
                failures.append(error)
            }
        }
        for (kind, label, link) in plan.added {
            let account = newAccount(kind: kind, label: label, hub: link)
            do {
                try credentialVault.save(link.credential, for: account.id)
                accounts.append(account)
            } catch {
                failures.append(error)
            }
        }
        AppLog.info(LogTag.auth("cliproxy"), "\(hub.host): \(plan.added.count) added, \(removed.count) removed, \(plan.relinked.count) relinked")
        persist()
        didChange?()
        if let failure = failures.first {
            AppLog.error(LogTag.auth("cliproxy"), "could not save \(failures.count) of \(hub.host)'s logins in the Keychain: \(failure.localizedDescription)")
            throw ProviderError.unavailable("OpenUsage couldn’t save this hub’s logins in the Keychain. It tries again when Accounts opens.")
        }
    }

    /// A card id keeps only the first 8 hex digits of the account's id, and two cards with one id crash
    /// the dashboard, so an id whose card id is taken is drawn again.
    private func newAccount(
        kind: ProviderKind, label: String, organization: String? = nil, domain: String? = nil, hub: HubLink? = nil
    ) -> Account {
        while true {
            let account = Account(
                id: makeID(), kind: kind, label: Self.name(label, for: kind), organization: organization, domain: domain, hub: hub
            )
            if self.account(cardID: account.cardID) == nil { return account }
        }
    }

    private func persistHubs() {
        guard let data = try? JSONEncoder().encode(hubs) else {
            return AppLog.error(LogTag.auth("cliproxy"), "could not encode the hub list")
        }
        defaults.set(data, forKey: Self.hubsStorageKey)
    }

    private func persist() {
        guard let known = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(accounts)) as? [Any],
              let list = try? JSONSerialization.data(withJSONObject: known + unreadableEntries) else {
            return AppLog.error(LogTag.auth("accounts"), "could not encode the account list")
        }
        defaults.set(list, forKey: Self.storageKey)
    }
}
