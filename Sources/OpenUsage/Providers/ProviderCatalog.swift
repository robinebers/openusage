import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// `claudeCards` carries the extra Claude account cards found by the launch account pass
    /// (`ProviderAccountAssembly`). Each becomes an ordinary runtime inserted right after the default
    /// Claude card, with credentials and usage logs pinned to exactly its own config dir. The empty
    /// default keeps the historical single-card set for focused tests and callers that intentionally
    /// skip the account pass.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        defaultClaudeExtraLogRoots: [URL] = [],
        defaultClaudeCoworkRoots: [URL]? = nil,
        defaultClaudeOrganization: String? = nil
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Account cards slot in right after
        // their family's default card.
        //
        // Every baked `Provider.displayName` here is the DERIVED default — renames live only in the
        // account registry and are resolved at render time (`ProviderAccountRecord.resolvedDisplayName`),
        // so a baked name can never be a stale copy of one.
        var runtimes: [ProviderRuntime] = []
        runtimes.append(ClaudeProvider(
            // Once ANOTHER Claude account is known on this machine — an extra card, or a cowork
            // partition from an account that earned no card (no org pin) — an unpinned Desktop
            // fallback could follow that account's active org, fetching its usage onto the default
            // card. With the default account's own org known, the fallback stays available pinned
            // to that org; otherwise it is disabled rather than blind.
            authStore: ClaudeAuthStore(
                standardDesktopOrganization: defaultClaudeOrganization,
                allowsUnpinnedStandardDesktopFallback: claudeCards.isEmpty && defaultClaudeCoworkRoots == nil
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                additionalRoots: defaultClaudeExtraLogRoots,
                coworkRootsOverride: defaultClaudeCoworkRoots
            )
        ))
        for card in claudeCards {
            runtimes.append(claudeAccountRuntime(card: card))
        }
        runtimes += [
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return runtimes
    }

    /// An extra Claude account card: same provider machinery, credentials and logs pinned to one
    /// login (a config-dir home, or Claude Desktop's org-pinned cache for a Cowork account). The
    /// scanner's parse cache is partitioned per card so distinct homes never share records.
    private static func claudeAccountRuntime(card: ClaudeAccountCard) -> ClaudeProvider {
        let scope: ClaudeCredentialScope = switch card.credential {
        case .configDir(let path, let keychainLiteral):
            .configDir(path: path, keychainLiteral: keychainLiteral)
        case .desktop(let organization):
            .desktopOnly(organization: organization)
        }
        return ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: ClaudeAuthStore(scope: scope),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        )
    }
}
