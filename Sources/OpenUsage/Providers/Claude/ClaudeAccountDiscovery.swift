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
        let enumerated: [KeychainItemSummary]
        do {
            enumerated = try keychain.genericPasswordItems(withServicePrefix: authStore.baseKeychainService())
        } catch {
            AppLog.warn(.keychain, "Claude account enumeration failed: \(error.localizedDescription)")
            return []
        }
        // The default instance's own services (the bare service, plus the env `CLAUDE_CONFIG_DIR`
        // hash when set) belong to the default account, never to an extra one.
        let defaultServices = Set(authStore.keychainServiceCandidates())
        // Junk filter: agent sandboxes and one-shot `CLAUDE_CONFIG_DIR` sessions leave a suffixed
        // item per run — written once, never rotated — and they accumulate by the hundreds. A real
        // second login keeps getting its token rotated, so only items whose modification date moved
        // meaningfully past creation count as accounts (see `showsOngoingUse`). A brand-new real
        // login therefore appears after about a day of use — the price of zero junk with no setup.
        let candidates = enumerated.filter { !defaultServices.contains($0.service) && $0.showsOngoingUse() }
        let skipped = enumerated.count { !defaultServices.contains($0.service) && !$0.showsOngoingUse() }
        if skipped > 0 {
            AppLog.info(.keychain, "Claude account discovery skipped \(skipped) never-rotated one-shot login item(s)")
        }
        return candidates
            .map(\.service)
            .sorted()
            .map { DiscoveredAccount(keychainService: $0) }
            + desktopAccounts()
    }

    /// Claude Desktop logins beyond the active one. Desktop keeps one token-cache entry per signed-in
    /// organization; the ACTIVE organization already feeds the default card's Desktop fallback (see
    /// `ClaudeAuthStore.loadCredentialSet`), so every OTHER organization is an extra account. Read
    /// without keychain interaction: until the user's one-time Safe Storage grant (a manual refresh),
    /// the inventory is simply unavailable and Desktop accounts appear on a later launch.
    private func desktopAccounts() -> [DiscoveredAccount] {
        guard let inventory = authStore.desktop.organizationInventory(allowInteraction: false) else {
            return []
        }
        return inventory.organizations
            .filter { $0 != inventory.active }
            .map { DiscoveredAccount(desktopOrganization: $0) }
    }
}
