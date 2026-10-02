import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codex: CodexAccountDiscovery = CodexAccountDiscovery(),
        claudeIdentityKeys: [String: String] = [:],
        allowsUnattributedClaudeUsage: Bool = true
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider(
                logUsageScanner: ClaudeLogUsageScanner(
                    accountUUID: allowsUnattributedClaudeUsage ? nil : claudeIdentityKeys["claude"]
                ),
                allowsUnattributedPiUsage: allowsUnattributedClaudeUsage,
                sharedHistorySource: allowsUnattributedClaudeUsage ? nil : .claude(directories: [])
            )]
        } else {
            let sharedHistory: SharedLocalHistorySource? = claudeCards.contains { !$0.allowsUnattributedPiUsage }
                ? .claude(directories: Array(Set(claudeCards.flatMap(\.additionalLogDirectories)))) : nil
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
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage,
                    sharedHistorySource: sharedHistory
                )
            }
        }
        if codex.cards.isEmpty {
            providers.append(CodexProvider(
                authStore: CodexAuthStore(
                    additionalAuthHomes: codex.plainAuthHomes,
                    piCredentialSources: codex.plainPiCredentialSources
                ),
                logUsageScanner: CodexLogUsageScanner(
                    allowsUnattributedHistory: codex.allowsUnattributedHistory,
                    additionalHomes: codex.plainAuthHomes
                ),
                allowsUnattributedHistory: codex.allowsUnattributedHistory,
                sharedHistorySource: codex.allowsUnattributedHistory ? nil : .codex(homes: codex.plainAuthHomes)
            ))
        } else {
            let sharedHistory: SharedLocalHistorySource? = codex.cards.contains { !$0.allowsUnattributedHistory }
                ? .codex(homes: Array(Set(codex.cards.flatMap(\.logHomes)))) : nil
            providers += codex.cards.map { card in
                CodexProvider(
                    provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
                    authStore: CodexAuthStore(
                        expectedIdentity: card.identity,
                        additionalAuthHomes: card.authHomes,
                        piCredentialSources: card.piCredentialSources
                    ),
                    logUsageScanner: CodexLogUsageScanner(
                        allowsUnattributedHistory: card.allowsUnattributedHistory,
                        additionalHomes: card.logHomes
                    ),
                    allowsUnattributedHistory: card.allowsUnattributedHistory,
                    sharedHistorySource: sharedHistory
                )
            }
        }
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
}
