import Foundation
import Observation

/// Persists every provider's additional accounts and which account each provider card currently
/// shows. The default account is implicit (it has no record and its account key is the bare provider
/// id); only extra logins found by discovery live here. Records whose credential sources vanish are
/// kept — a user's rename and cached layout must not silently disappear — and can be removed
/// explicitly from Customize.
///
/// Reconcile logic adapted from PR #965 by Ryan George (@QuadDepo).
@MainActor
@Observable
final class ProviderAccountsStore {
    static let accountsKey = "openusage.providerAccounts.v1"
    static let selectionKey = "openusage.providerAccounts.selection.v1"

    private let defaults: UserDefaults
    private(set) var accounts: [ProviderAccount]
    /// Which extra account each provider card shows; a provider absent here shows its default account.
    /// Values are validated on read so a removed account can never leave a card pointing at nothing.
    private var selection: [String: UUID]

    /// Wired by `AppContainer`: called with the provider id after a selection change so the data
    /// store can swap the displayed snapshot (and fetch the newly selected account if needed).
    @ObservationIgnored var onSelectionChange: (@MainActor (String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accounts = Self.loadAccounts(from: defaults)
        self.selection = Self.loadSelection(from: defaults)
    }

    // MARK: - Reads

    /// The provider's extra accounts, in stored (discovery) order. Empty for a single-login provider.
    func accounts(for providerID: String) -> [ProviderAccount] {
        accounts.filter { $0.providerID == providerID }
    }

    func account(id: UUID) -> ProviderAccount? {
        accounts.first { $0.id == id }
    }

    /// Whether the provider's header should show the account picker at all.
    func hasExtraAccounts(for providerID: String) -> Bool {
        accounts.contains { $0.providerID == providerID }
    }

    /// The selected extra account, or `nil` when the card shows the default account (also the answer
    /// when a stale selection points at a removed record).
    func selectedAccountID(for providerID: String) -> UUID? {
        guard let id = selection[providerID], account(id: id) != nil else { return nil }
        return id
    }

    /// The data/cache key of the account the provider card currently shows — the bare provider id
    /// for the default account. This is the single seam `WidgetDataStore` resolves through.
    func selectedAccountKey(for providerID: String) -> String {
        guard let id = selectedAccountID(for: providerID), let record = account(id: id) else {
            return providerID
        }
        return record.accountKey
    }

    // MARK: - Mutations

    /// Show a different account on the provider's card (`nil` = the default account). Persists the
    /// choice and notifies the data store so the swap is instant.
    func select(accountID: UUID?, for providerID: String) {
        if let accountID, account(id: accountID) != nil {
            selection[providerID] = accountID
        } else {
            selection[providerID] = nil
        }
        persistSelection()
        onSelectionChange?(providerID)
    }

    /// Merge one provider's discovery results into the stored set: a record sharing a credential
    /// source keeps its UUID (absorbing any newly linked source), genuinely new sources get fresh
    /// records. Records discovery no longer returns are pruned UNLESS the user renamed them — a
    /// rename is the user claiming the account, so it survives a vanished login (showing "Not logged
    /// in" when selected) until they remove it themselves; an unclaimed record tracks discovery, so
    /// junk that a smarter filter later rejects cleans itself up. Returns the provider's records
    /// after the merge.
    @discardableResult
    func reconcile(providerID: String, discovered: [DiscoveredAccount]) -> [ProviderAccount] {
        var matchedIDs = Set<UUID>()
        for source in discovered {
            if let index = accounts.firstIndex(where: { $0.providerID == providerID && $0.matches(source) }) {
                if let dir = source.configDir { accounts[index].configDir = dir }
                if let service = source.keychainService {
                    accounts[index].keychainService = service
                    accounts[index].keychainAccount = source.keychainAccount
                }
                if let organization = source.desktopOrganization {
                    accounts[index].desktopOrganization = organization
                }
                let survivorID = accounts[index].id
                matchedIDs.insert(survivorID)
                collapseSubsumedRecords(into: survivorID)
            } else {
                let record = ProviderAccount(
                    id: UUID(),
                    providerID: providerID,
                    configDir: source.configDir,
                    keychainService: source.keychainService,
                    keychainAccount: source.keychainAccount,
                    desktopOrganization: source.desktopOrganization,
                    customName: nil
                )
                matchedIDs.insert(record.id)
                accounts.append(record)
            }
        }
        let pruned = accounts.filter {
            $0.providerID == providerID && !matchedIDs.contains($0.id) && $0.customName == nil
        }
        if !pruned.isEmpty {
            AppLog.info(.config, "pruned \(pruned.count) undiscovered unnamed \(providerID) account record(s)")
            let prunedIDs = Set(pruned.map(\.id))
            accounts.removeAll { prunedIDs.contains($0.id) }
            if let selected = selection[providerID], prunedIDs.contains(selected) {
                selection[providerID] = nil
                persistSelection()
            }
        }
        persistAccounts()
        return accounts(for: providerID)
    }

    /// Set (or clear) a custom name. The header picker and Customize both read this store (it's
    /// `@Observable`), so the rename shows immediately.
    func setCustomName(_ name: String?, forID id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].customName = (trimmed?.isEmpty == false) ? trimmed : nil
        persistAccounts()
    }

    /// Forget an extra account (Customize's remove action). If it was the one on screen, the card
    /// falls back to the default account.
    func remove(id: UUID) {
        guard let record = account(id: id) else { return }
        accounts.removeAll { $0.id == id }
        persistAccounts()
        if selection[record.providerID] == id {
            select(accountID: nil, for: record.providerID)
        }
    }

    // MARK: - Internals

    /// After a matched record absorbed a newly linked source, drop any sibling whose sources it now
    /// fully carries — the file-only + keychain-only split discovery has resolved into one account.
    /// The survivor keeps its (older) UUID; a custom name from a collapsed record is adopted when the
    /// survivor has none, so a rename is never lost in the merge.
    private func collapseSubsumedRecords(into survivorID: UUID) {
        guard let survivorIndex = accounts.firstIndex(where: { $0.id == survivorID }) else { return }
        let survivor = accounts[survivorIndex]
        var adoptedName = survivor.customName
        accounts.removeAll { record in
            guard record.isSubsumed(by: survivor) else { return false }
            if adoptedName == nil { adoptedName = record.customName }
            return true
        }
        if let index = accounts.firstIndex(where: { $0.id == survivorID }) {
            accounts[index].customName = adoptedName
        }
    }

    private func persistAccounts() {
        do {
            defaults.set(try JSONEncoder().encode(accounts), forKey: Self.accountsKey)
        } catch {
            AppLog.error(.config, "failed to persist provider accounts: \(error.localizedDescription)")
        }
    }

    private func persistSelection() {
        let encoded = selection.mapValues(\.uuidString)
        defaults.set(encoded, forKey: Self.selectionKey)
    }

    private static func loadAccounts(from defaults: UserDefaults) -> [ProviderAccount] {
        guard let data = defaults.data(forKey: accountsKey) else { return [] }
        do {
            return try JSONDecoder().decode([ProviderAccount].self, from: data)
        } catch {
            AppLog.error(.config, "failed to load provider accounts: \(error.localizedDescription)")
            return []
        }
    }

    private static func loadSelection(from defaults: UserDefaults) -> [String: UUID] {
        guard let stored = defaults.dictionary(forKey: selectionKey) as? [String: String] else { return [:] }
        return stored.compactMapValues(UUID.init(uuidString:))
    }
}
