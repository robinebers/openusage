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
        instanceContext: ProviderInstanceContext? = nil,
        codexIdentityCache: (any CodexHomeIdentityCaching)? = nil,
        codexIdentityDidResolve: (@MainActor @Sendable (_ providerID: String, _ identityKey: String) -> Void)? = nil
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
                rootsOverride: instanceContext?.defaultClaudeLogRoots,
                coworkRootsOverride: instanceContext?.defaultClaudeCoworkRoots
            )
        }
        let visibleClaudeInstances = instanceContext?.records(forBase: "claude") ?? []
        let defaultClaudeOrganization = claudeOrganization(
            fromIdentityKey: instanceContext?.defaultClaudeIdentityKey
        )
        let defaultClaudeExtraScanners = (instanceContext?.defaultClaudeAdditionalLogRoots ?? []).isEmpty
            ? []
            : [ClaudeLogUsageScanner(
                rootsOverride: instanceContext?.defaultClaudeAdditionalLogRoots,
                coworkRootsOverride: []
            )]
        let defaultClaudeIdentityReader: (@Sendable () -> String?)?
        if instanceContext?.defaultClaudeIdentityKey != nil {
            defaultClaudeIdentityReader = {
                ProviderInstanceDiscovery().defaultClaudeIdentityKey()
            }
        } else {
            defaultClaudeIdentityReader = nil
        }
        runtimes.append(ClaudeProvider(
            provider: ClaudeProvider.makeProvider(
                displayName: instanceContext?.defaultDisplayName(forBase: "claude", name: "Claude") ?? "Claude"
            ),
            authStore: ClaudeAuthStore(
                standardDesktopOrganization: defaultClaudeOrganization,
                // Preserve historical active-org fallback on single-account installs. Once another
                // Claude card exists, an unpinned fallback could borrow that instance's Desktop token.
                allowsUnpinnedStandardDesktopFallback: visibleClaudeInstances.isEmpty
            ),
            logUsageScanner: defaultClaudeScanner,
            extraLogUsageScanners: defaultClaudeExtraScanners,
            expectedIdentityKey: instanceContext?.defaultClaudeIdentityKey,
            currentIdentityKey: defaultClaudeIdentityReader
        ))
        for record in visibleClaudeInstances {
            runtimes.append(claudeInstance(record: record, context: instanceContext!))
        }

        runtimes.append(CodexProvider(
            provider: CodexProvider.makeProvider(
                displayName: instanceContext?.defaultDisplayName(forBase: "codex", name: "Codex") ?? "Codex"
            ),
            authStore: CodexAuthStore(identityCache: codexIdentityCache),
            identityDidResolve: codexIdentityHandler(
                providerID: "codex",
                relay: codexIdentityDidResolve
            ),
            logUsageScanner: CodexLogUsageScanner(
                relatedHomesByCanonicalHome: instanceContext?.codexRelatedLogRootsByHome ?? [:]
            )
        ))
        for record in instanceContext?.records(forBase: "codex") ?? [] {
            runtimes.append(codexInstance(
                record: record,
                context: instanceContext!,
                identityCache: codexIdentityCache,
                identityDidResolve: codexIdentityDidResolve
            ))
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

    private static func claudeOrganization(fromIdentityKey identityKey: String?) -> String? {
        guard let identityKey,
              let separator = identityKey.firstIndex(of: "|")
        else { return nil }
        return String(identityKey[identityKey.index(after: separator)...]).nilIfEmpty?.lowercased()
    }

    private static func codexIdentityHandler(
        providerID: String,
        relay: (@MainActor @Sendable (_ providerID: String, _ identityKey: String) -> Void)?
    ) -> (@MainActor @Sendable (_ identityKey: String) -> Void)? {
        guard let relay else { return nil }
        return { identityKey in relay(providerID, identityKey) }
    }

    /// A Claude instance runtime: same provider machinery, credentials and logs pinned to one login.
    private static func claudeInstance(
        record: ProviderInstanceRecord,
        context: ProviderInstanceContext
    ) -> ClaudeProvider {
        let provider = ClaudeProvider.makeProvider(id: record.id, displayName: context.displayName(for: record, baseName: "Claude"))
        // Discovery folds every source with the same account identity onto one card. This collection
        // therefore includes Cowork sandboxes and any non-primary config homes whose logs must survive
        // source preference (for example, a cswap vault credential plus a custom config-dir history).
        // Reconciliation deliberately keeps a card's original id across a re-login, so the discovery
        // map's current identity-derived id can differ from `record.id`. Consult both forms or those
        // roots disappear for exactly the lifecycle path stable ids are meant to preserve.
        let identityDerivedID = ProviderInstanceID.make(
            baseProviderID: record.baseProviderID,
            identityKey: record.identityKey
        )
        let additionalRoots = context.coworkRootsByInstanceID[record.id]
            ?? context.coworkRootsByInstanceID[identityDerivedID]
            ?? []
        switch record.kind {
        case .claudeDesktop:
            return ClaudeProvider(
                provider: provider,
                authStore: ClaudeAuthStore(scope: .desktopOnly(organization: record.desktopOrganization)),
                logUsageScanner: ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: additionalRoots)
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
                if !additionalRoots.isEmpty {
                    extraScanners.append(ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: additionalRoots))
                }
            } else {
                primaryScanner = ClaudeLogUsageScanner(rootsOverride: [], coworkRootsOverride: additionalRoots)
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
            var extraScanners: [ClaudeLogUsageScanner] = []
            // A config home can represent the same account as a cswap slot. Its credential remains
            // pinned to that home, while its periods in the shared default roots still belong here.
            if let timeline = context.claudeSwapTimeline, !context.claudeSharedHomeRoots.isEmpty {
                extraScanners.append(ClaudeLogUsageScanner(
                    rootsOverride: context.claudeSharedHomeRoots,
                    coworkRootsOverride: [],
                    entryFilter: timeline.entryFilter(identityKey: record.identityKey, includeUnknown: false)
                ))
            }
            return ClaudeProvider(
                provider: provider,
                authStore: ClaudeAuthStore(scope: .configDir(
                    path: path,
                    keychainLiteral: record.keychainLiteral ?? path
                )),
                logUsageScanner: ClaudeLogUsageScanner(
                    rootsOverride: [URL(fileURLWithPath: path)],
                    coworkRootsOverride: additionalRoots
                ),
                extraLogUsageScanners: extraScanners
            )
        }
    }

    /// A Codex instance runtime: `auth.json` + the home's computed keychain item, with credentials
    /// pinned to that home and logs merged from every home verified to carry the same account.
    private static func codexInstance(
        record: ProviderInstanceRecord,
        context: ProviderInstanceContext,
        identityCache: (any CodexHomeIdentityCaching)?,
        identityDidResolve: (@MainActor @Sendable (_ providerID: String, _ identityKey: String) -> Void)?
    ) -> CodexProvider {
        let path = expandHome(record.anchorPath ?? "")
        return CodexProvider(
            provider: CodexProvider.makeProvider(id: record.id, displayName: context.displayName(for: record, baseName: "Codex")),
            authStore: CodexAuthStore(
                scope: .home(path: path),
                identityCache: identityCache
            ),
            identityDidResolve: codexIdentityHandler(
                providerID: record.id,
                relay: identityDidResolve
            ),
            logUsageScanner: CodexLogUsageScanner(
                environment: ScopedEnvironmentReader(
                    base: ProcessEnvironmentReader(),
                    overrides: ["CODEX_HOME": path]
                ),
                relatedHomesByCanonicalHome: context.codexRelatedLogRootsByHome
            )
        )
    }
}
