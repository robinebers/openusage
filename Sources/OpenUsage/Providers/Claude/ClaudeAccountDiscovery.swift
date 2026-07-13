import Foundation

/// Finds additional Claude Code logins on this Mac. Keychain-only by design: on macOS the keychain
/// is Claude Code's source of truth (see `ClaudeAuthStore.orderedStoredCandidates`), and every login
/// is one generic-password item — the default account under the bare `Claude Code-credentials`
/// service, each `CLAUDE_CONFIG_DIR`-based login under a hash-suffixed sibling service. So one
/// attributes-only enumeration (no secret read, no unlock prompt) lists every account; anything
/// beyond the default instance's own services is an extra account.
///
/// Adapted from PR #965 by Ryan George (@QuadDepo).
struct ClaudeAccountDiscovery {
    var authStore: ClaudeAuthStore
    var keychain: KeychainAccessing

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.authStore = authStore
        self.keychain = keychain
    }

    func discoverExtraAccounts() -> [DiscoveredAccount] {
        let enumerated: [String]
        do {
            enumerated = try keychain.genericPasswordServices(withPrefix: authStore.baseKeychainService())
        } catch {
            AppLog.warn(.keychain, "Claude account enumeration failed: \(error.localizedDescription)")
            return []
        }
        // The default instance's own services (the bare service, plus the env `CLAUDE_CONFIG_DIR`
        // hash when set) belong to the default account, never to an extra one.
        let defaultServices = Set(authStore.keychainServiceCandidates())
        return enumerated
            .filter { !defaultServices.contains($0) }
            .sorted()
            .map { DiscoveredAccount(configDir: nil, keychainService: $0, keychainAccount: nil) }
    }
}
