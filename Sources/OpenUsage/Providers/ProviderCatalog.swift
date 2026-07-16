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

        // On a swap-tool machine the default card's spend must exclude the periods other accounts were
        // active — its filter takes its own periods PLUS unknown time (pre-history spend is never
        // dropped). Without a timeline the scanner is byte-identical to before.
        let defaultClaudeScanner: ClaudeLogUsageScanner
        if let context = instanceContext, let timeline = context.claudeSwapTimeline,
           let defaultKey = context.defaultClaudeIdentityKey, !context.claudeSharedHomeRoots.isEmpty {
            defaultClaudeScanner = ClaudeLogUsageScanner(
                rootsOverride: context.claudeSharedHomeRoots,
                coworkRootsOverride: context.defaultClaudeCoworkRoots,
                entryFilter: timeline.entryFilter(identityKey: defaultKey, includeUnknown: true)
            )
        } else {
            defaultClaudeScanner = ClaudeLogUsageScanner(
                coworkRootsOverride: instanceContext?.defaultClaudeCoworkRoots
            )
        }
        runtimes.append(ClaudeProvider(
            provider: ClaudeProvider.makeProvider(
                displayName: instanceContext?.defaultDisplayName(forBase: "claude", name: "Claude") ?? "Claude"
            ),
            logUsageScanner: defaultClaudeScanner
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
        case .claudeSwapSlot:
            // A parked cswap slot: read-only vault credential (+ org-pinned Desktop fallback). Spend:
            // this account's time slices of the SHARED home (attributed via the switch timeline) plus
            // its own Cowork sandboxes. Without a timeline the shared logs stay on the default card.
            let primaryScanner: ClaudeLogUsageScanner
            var extraScanners: [ClaudeLogUsageScanner] = []
            if let timeline = context.claudeSwapTimeline, !context.claudeSharedHomeRoots.isEmpty {
                primaryScanner = ClaudeLogUsageScanner(
                    rootsOverride: context.claudeSharedHomeRoots,
                    coworkRootsOverride: [],
                    entryFilter: timeline.entryFilter(identityKey: record.identityKey, includeUnknown: false)
                )
                if !coworkRoots.isEmpty {
                    extraScanners.append(ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: coworkRoots))
                }
            } else {
                primaryScanner = ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: coworkRoots)
            }
            return ClaudeProvider(
                provider: provider,
                authStore: ClaudeAuthStore(scope: .swapSlot(
                    account: record.swapAccountName ?? "",
                    backupRoot: record.anchorPath ?? "",
                    organization: record.desktopOrganization
                )),
                logUsageScanner: primaryScanner,
                extraLogUsageScanners: extraScanners
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
