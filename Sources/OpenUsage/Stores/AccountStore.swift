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
    func add(kind: ProviderKind, label: String, credential: AccountCredential) -> Account {
        let account = Account(kind: kind, label: label)
        do {
            try credentialVault.save(credential, for: account.id)
            accounts.append(account)
            if persist() {
                didChange?()
            } else {
                accounts.removeAll { $0.id == account.id }
                do {
                    try credentialVault.delete(account.id)
                } catch {
                    AppLog.error(LogTag.auth("accounts"), "could not roll back account credential: \(error.localizedDescription)")
                }
            }
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("accounts"), "could not save account: \(error.localizedDescription)")
        }
        return account
    }

    func rename(_ id: UUID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let previous = accounts[index].label
        accounts[index].label = label
        if persist() {
            didChange?()
        } else {
            accounts[index].label = previous
        }
    }

    func remove(_ id: UUID) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == id }) else { return }
        do {
            let credential = try credentialVault.load(id)
            try credentialVault.delete(id)
            let account = accounts.remove(at: accountIndex)
            if persist() {
                didChange?()
                return
            }
            accounts.insert(account, at: accountIndex)
            if let credential {
                do {
                    try credentialVault.save(credential, for: id)
                } catch {
                    AppLog.error(LogTag.auth("accounts"), "could not restore account credential: \(error.localizedDescription)")
                }
            }
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("accounts"), "could not remove account credential: \(error.localizedDescription)")
        }
    }

    func credential(for id: UUID) throws -> AccountCredential? {
        try credentialVault.load(id)
    }

    func account(kind: ProviderKind, signedInAs credential: AccountCredential) -> Account? {
        guard let identity = credential.identity else { return nil }
        return accounts.first { account in
            account.kind == kind && (try? credentialVault.load(account.id))??.identity == identity
        }
    }

    func account(cardID: String) -> Account? {
        accounts.first { $0.cardID == cardID }
    }

    private func persist() -> Bool {
        do {
            defaults.set(try JSONEncoder().encode(accounts), forKey: Self.storageKey)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("accounts"), "could not persist account list: \(error.localizedDescription)")
            return false
        }
    }
}
