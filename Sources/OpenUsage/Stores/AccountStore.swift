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

    init(defaults: UserDefaults = .standard, vault: any CredentialVault = KeychainCredentialVault()) {
        self.defaults = defaults
        credentialVault = vault
        let stored = Self.load(from: defaults)
        accounts = stored.accounts
        unreadableEntries = stored.unreadableEntries
        hubs = defaults.data(forKey: Self.hubsStorageKey).flatMap { data in
            do {
                return try JSONDecoder().decode([CLIProxyHub].self, from: data)
            } catch {
                AppLog.error(LogTag.auth("cliproxy"), "cannot read the stored hub list: \(error)")
                return nil
            }
        } ?? []
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
    func add(kind: ProviderKind, label: String, organization: String? = nil, credential: AccountCredential) -> Account {
        let account = Account(kind: kind, label: label, organization: organization)
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
        accounts[index].label = label
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
        guard accounts.contains(where: { $0.id == id }) else { return }
        try credentialVault.save(credential, for: id)
    }

    func credential(for id: UUID) throws -> AccountCredential? {
        try credentialVault.load(id)
    }

    /// The added account a new sign-in would duplicate: an organization account by its organization,
    /// in any case, and every other account by its credential's identity. An account mirrored from a hub
    /// never counts, so a login signed in both directly and on a hub shows twice.
    func account(kind: ProviderKind, organization: String?, signedInAs credential: AccountCredential) -> Account? {
        if let organization {
            return accounts.first { $0.kind == kind && $0.organization?.caseInsensitiveCompare(organization) == .orderedSame }
        }
        guard let identity = credential.identity else { return nil }
        return accounts.first { account in
            account.kind == kind && account.hub == nil && (try? credentialVault.load(account.id))??.identity == identity
        }
    }

    func account(cardID: String) -> Account? {
        accounts.first { $0.cardID == cardID }
    }

    func accounts(onHub hubID: UUID) -> [Account] {
        accounts.filter { $0.hub?.hubID == hubID }
    }

    /// Saves a newly connected hub and its management key. Its logins arrive with `mirror`.
    func addHub(_ hub: CLIProxyHub, key: String) throws {
        try credentialVault.save(.apiKey(key), for: hub.id)
        hubs.append(hub)
        persistHubs()
    }

    func replaceHubKey(_ key: String, for hubID: UUID) throws {
        guard hubs.contains(where: { $0.id == hubID }) else { return }
        try credentialVault.save(.apiKey(key), for: hubID)
    }

    /// Removes a hub together with every account mirrored from it and its management key.
    func removeHub(_ hubID: UUID) {
        let mirrored = Set(accounts(onHub: hubID).map(\.id))
        do {
            for id in mirrored { try credentialVault.delete(id) }
            try credentialVault.delete(hubID)
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
    /// provider's accounts, a login gone from the hub is removed, and a renamed or disabled one is
    /// relinked. The same listing applied twice changes nothing the second time.
    func mirror(_ logins: [HubLogin], from hubID: UUID) {
        guard let hub = hubs.first(where: { $0.id == hubID }) else { return }
        let plan = HubReconciliation(hub: hub, logins: logins, accounts: accounts)
        guard !plan.isEmpty else { return }
        var removed = Set<UUID>()
        for id in plan.removed {
            do {
                try credentialVault.delete(id)
                removed.insert(id)
            } catch {
                AppLog.error(LogTag.auth("cliproxy"), "could not remove a login gone from \(hub.host): \(error.localizedDescription)")
            }
        }
        accounts.removeAll { removed.contains($0.id) }
        for index in accounts.indices {
            if let link = plan.relinked[accounts[index].id] { accounts[index].hub = link }
        }
        for (kind, login) in plan.added {
            let account = Account(kind: kind, label: login.label, hub: HubLink(hub: hub, login: login))
            let extras = login.chatGPTAccountID.map { ["chatgpt_account_id": $0] } ?? [:]
            do {
                try credentialVault.save(.oauth(OAuthTokens(accessToken: CLIProxyHubClient.tokenPlaceholder, extras: extras)), for: account.id)
                accounts.append(account)
            } catch {
                AppLog.error(LogTag.auth("cliproxy"), "could not save a login from \(hub.host): \(error.localizedDescription)")
            }
        }
        AppLog.info(LogTag.auth("cliproxy"), "\(hub.host): \(plan.added.count) added, \(removed.count) removed, \(plan.relinked.count) relinked")
        persist()
        didChange?()
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
