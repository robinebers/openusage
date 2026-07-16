import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// `instanceContext` carries the discovered extra logins (provider instances). Each becomes an
    /// ordinary runtime inserted right after its base provider, with credentials and usage logs pinned
    /// to exactly its own home. `nil` (the one-shot CLI, tests) keeps the default-only set.
    static func make(
        defaults: UserDefaults = .standard,
        instanceContext: ProviderInstanceContext? = nil
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        var runtimes: [ProviderRuntime] = []

        runtimes.append(ClaudeProvider(
            provider: ClaudeProvider.makeProvider(
                displayName: instanceContext?.defaultDisplayName(forBase: "claude", name: "Claude") ?? "Claude"
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                coworkRootsOverride: instanceContext?.defaultClaudeCoworkRoots
            )
        ))
        for record in instanceContext?.records(forBase: "claude") ?? [] {
            runtimes.append(claudeInstance(record: record, context: instanceContext!))
        }

        runtimes.append(CodexProvider(
            provider: CodexProvider.makeProvider(
                displayName: instanceContext?.defaultDisplayName(forBase: "codex", name: "Codex") ?? "Codex"
            )
        ))
        for record in instanceContext?.records(forBase: "codex") ?? [] {
            runtimes.append(codexInstance(record: record))
        }

        runtimes += [
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

    /// A Claude instance runtime: same provider machinery, credentials and logs pinned to one login.
    private static func claudeInstance(
        record: ProviderInstanceRecord,
        context: ProviderInstanceContext
    ) -> ClaudeProvider {
        let provider = ClaudeProvider.makeProvider(id: record.id, displayName: "Claude \(record.ordinal)")
        let coworkRoots = context.coworkRootsByInstanceID[record.id] ?? []
        switch record.kind {
        case .claudeDesktop:
            return ClaudeProvider(
                provider: provider,
                authStore: ClaudeAuthStore(scope: .desktopOnly(organization: record.desktopOrganization)),
                logUsageScanner: ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: coworkRoots)
            )
        default:
            let path = expandHome(record.anchorPath ?? "")
            return ClaudeProvider(
                provider: provider,
                authStore: ClaudeAuthStore(scope: .configDir(
                    path: path,
                    keychainLiteral: record.keychainLiteral ?? path
                )),
                logUsageScanner: ClaudeLogUsageScanner(
                    rootsOverride: [URL(fileURLWithPath: path)],
                    coworkRootsOverride: coworkRoots
                )
            )
        }
    }

    /// A Codex instance runtime: `auth.json` + the home's computed keychain item, logs from that home
    /// only (the scanner's `CODEX_HOME` is pinned via a scoped environment).
    private static func codexInstance(record: ProviderInstanceRecord) -> CodexProvider {
        let path = expandHome(record.anchorPath ?? "")
        return CodexProvider(
            provider: CodexProvider.makeProvider(id: record.id, displayName: "Codex \(record.ordinal)"),
            authStore: CodexAuthStore(scope: .home(path: path)),
            logUsageScanner: CodexLogUsageScanner(
                environment: ScopedEnvironmentReader(
                    base: ProcessEnvironmentReader(),
                    overrides: ["CODEX_HOME": path]
                )
            )
        )
    }
}
