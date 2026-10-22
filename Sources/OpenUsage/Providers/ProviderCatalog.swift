import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codex: CodexAccountDiscovery = CodexAccountDiscovery(),
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
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage,
                    additionalConfigDirectories: card.additionalLogDirectories
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
                        swapAccount: card.swapAccount,
                        preferOrganizationScopedDesktop: claudeCards.count > 1
                            && card.organizationID != nil && !card.usesDesktopCredentials
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        providers += makeCodexProviders(codex)
        providers += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OllamaProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }

    /// The Codex family alone: the plain card, or one card per account. Also what the live reload
    /// after a Codex account change rebuilds, leaving every other provider's runtime in place.
    static func makeCodexProviders(_ codex: CodexAccountDiscovery) -> [ProviderRuntime] {
        if codex.cards.isEmpty {
            return [CodexProvider(
                authStore: CodexAuthStore(
                    additionalAuthHomes: codex.plainAuthHomes,
                    writableAuthHomes: Set(codex.plainWritableAuthHomes),
                    piCredentialSources: codex.plainPiCredentialSources
                ),
                logUsageScanner: CodexLogUsageScanner(additionalHomes: codex.plainAuthHomes)
            )]
        }
        return codex.cards.map { card in
            CodexProvider(
                // One account left reads as plain "Codex" again, as a lone Claude card is "Claude";
                // the card keeps its id, scope, and stamps.
                provider: CodexProvider.makeProvider(
                    id: card.id, displayName: codex.cards.count == 1 ? "Codex" : card.displayName
                ),
                authStore: CodexAuthStore(
                    expectedIdentity: card.identity,
                    additionalAuthHomes: card.authHomes,
                    writableAuthHomes: Set(card.writableAuthHomes),
                    piCredentialSources: card.piCredentialSources
                ),
                historyScope: .account(card.identity, codex.historyHomes, claimsPiUsage: card.claimsPiUsage),
                hasManagedLogin: card.hasManagedLogin
            )
        }
    }

    /// `providers` with its Codex family swapped for `codex`, in the family's place (after the
    /// Claude cards, before Cursor), so the canonical order survives a reload.
    static func replacingCodexProviders(in providers: [ProviderRuntime], with codex: [ProviderRuntime]) -> [ProviderRuntime] {
        let isCodex: (ProviderRuntime) -> Bool = { ProviderAccountID.family(of: $0.provider.id) == "codex" }
        guard let first = providers.firstIndex(where: isCodex) else { return providers }
        let rest = providers[first...].drop(while: isCodex)
        return Array(providers[..<first]) + codex + Array(rest)
    }
}
