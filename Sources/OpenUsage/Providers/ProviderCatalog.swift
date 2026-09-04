import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        claudeIdentityKeys: [String: String] = [:]
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider()]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        preferOrganizationScopedDesktop: claudeCards.count > 1 && !card.usesDesktopCredentials
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        providers += [
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
        return providers
    }
}
