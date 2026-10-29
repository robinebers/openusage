import Foundation
import Observation

@MainActor
@Observable
final class AccountStore {
    static let storageKey = "accounts.v1"

    private(set) var accounts: [Account]
    private(set) var lastError: String?
    @ObservationIgnored var didChange: (() -> Void)?
    private let defaults: UserDefaults
    let credentialVault: any CredentialVault

    init(defaults: UserDefaults = .standard, vault: any CredentialVault = KeychainCredentialVault()) {
        self.defaults = defaults
        credentialVault = vault
        accounts = Self.load(from: defaults)
    }

    static func load(from defaults: UserDefaults) -> [Account] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return decoded.sorted { $0.addedAt < $1.addedAt }
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
    /// in any case, and every other account by its credential's identity.
    func account(kind: ProviderKind, organization: String?, signedInAs credential: AccountCredential) -> Account? {
        if let organization {
            return accounts.first { $0.kind == kind && $0.organization?.caseInsensitiveCompare(organization) == .orderedSame }
        }
        guard let identity = credential.identity else { return nil }
        return accounts.first { account in
            account.kind == kind && (try? credentialVault.load(account.id))??.identity == identity
        }
    }

    func account(cardID: String) -> Account? {
        accounts.first { $0.cardID == cardID }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else {
            return AppLog.error(LogTag.auth("accounts"), "could not encode the account list")
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
