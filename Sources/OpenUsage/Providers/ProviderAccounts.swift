import Foundation

/// One credential source a provider's account discovery found on the machine — an address only
/// (a config directory, a keychain item, or both); no secret is ever copied. Discovery returns
/// EXTRA accounts exclusively: the provider's normal login (its auth store's default resolution)
/// is never represented as a `DiscoveredAccount`.
struct DiscoveredAccount: Hashable, Sendable {
    /// Config directory holding the account's credential file (e.g. a second `CODEX_HOME`).
    var configDir: String?
    /// Keychain service name, for providers that distinguish accounts by service
    /// (Claude Code: `Claude Code-credentials-<hash>`).
    var keychainService: String?
    /// Keychain account attribute, for providers that keep one service and distinguish accounts by
    /// account name (Codex: service `Codex Auth`, account `cli|<hash>`).
    var keychainAccount: String?
}

/// One persisted additional login for a provider. The default account is NEVER stored — only extra
/// accounts get a record, a stable UUID, and with it a stable `accountKey` so their cached snapshot
/// and custom name survive relaunches even when the credential source moves between file and keychain.
struct ProviderAccount: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var providerID: String
    var configDir: String?
    var keychainService: String?
    var keychainAccount: String?
    /// User-supplied display name from Customize. `nil` falls back to a short id-derived name.
    var customName: String?

    /// The key this account's snapshots are cached and refreshed under. The default account of every
    /// provider uses the bare provider id (which is why existing caches need no migration); extras get
    /// a namespaced key.
    var accountKey: String { "\(providerID)@\(id.uuidString.lowercased())" }

    /// Shown in the account picker and Customize: the custom name when set, else a short stable
    /// id-derived tag the user can recognize until they rename it.
    var displayName: String {
        if let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return "Account \(String(id.uuidString.lowercased().prefix(8)))"
    }

    /// Whether a freshly discovered credential source refers to this account (any shared source
    /// counts). Used by reconcile to keep the UUID stable across launches.
    func matches(_ discovered: DiscoveredAccount) -> Bool {
        if let dir = discovered.configDir, dir == configDir { return true }
        if let service = discovered.keychainService, keychainAccount == nil, discovered.keychainAccount == nil,
           service == keychainService {
            return true
        }
        if let account = discovered.keychainAccount, account == keychainAccount,
           discovered.keychainService == keychainService {
            return true
        }
        return false
    }

    /// Whether every credential source this record carries is also carried by `other` (which must
    /// share at least one), so `other` fully represents this account and this record is a stale
    /// duplicate. Collapses a file-only + keychain-only pair once discovery links them into one.
    func isSubsumed(by other: ProviderAccount) -> Bool {
        guard id != other.id, providerID == other.providerID else { return false }
        var sharesSource = false
        if let dir = configDir {
            guard dir == other.configDir else { return false }
            sharesSource = true
        }
        if keychainService != nil || keychainAccount != nil {
            guard keychainService == other.keychainService, keychainAccount == other.keychainAccount else {
                return false
            }
            sharesSource = true
        }
        return sharesSource
    }
}

/// A provider runtime bound to one account, under the key its data is cached and refreshed by.
/// `AppContainer` builds one per account at launch (the default account's runtime is the provider's
/// normal instance); `WidgetDataStore` drives them all and projects the selected one onto the card.
@MainActor
struct AccountRuntime {
    let providerID: String
    /// The bare provider id for the default account, `ProviderAccount.accountKey` for extras.
    let accountKey: String
    let runtime: ProviderRuntime
}

/// A provider whose card can be fed by more than one login found on the machine. The conforming
/// runtime IS the default account; at launch the app asks it for extra accounts and for one scoped
/// sibling runtime per persisted record. Accounts deliberately do NOT change anything else — metric
/// ids, layout, pins, and enablement stay per-provider; the account picker only swaps which login's
/// data fills the card.
@MainActor
protocol MultiAccountProviderRuntime: ProviderRuntime {
    /// Cheap, local-only scan for additional logins (file stats and attributes-only keychain
    /// enumeration; never the network, never a secret read). Runs synchronously at launch.
    func discoverExtraAccounts() -> [DiscoveredAccount]
    /// A runtime pinned to exactly this account's credential sources — no cross-account fallback,
    /// no env-token fallback. Shares the provider identity and descriptors with the default runtime.
    func makeAccountRuntime(for account: ProviderAccount) -> ProviderRuntime
}
