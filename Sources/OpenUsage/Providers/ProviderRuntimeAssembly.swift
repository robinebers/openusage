import Foundation

/// Builds the complete provider runtime set for one process, including discovered Claude/Codex
/// account instances. The menu-bar app and one-shot CLI both use this so account ownership, duplicate
/// suppression, credential scoping, log partitioning, and stable instance ids cannot drift.
@MainActor
struct ProviderRuntimeAssembly {
    let providers: [ProviderRuntime]
    let providerIdentityKeys: [String: String]

    private let codexIdentityCache: CodexHomeIdentityCache
    private let unverifiedCodexKeyringHomes: Set<String>

    static func make(
        defaults: UserDefaults = .standard,
        shellEnvironmentReady: Bool? = nil,
        discovery: ((CodexHomeIdentityCache) -> ProviderInstanceDiscovery.Result)? = nil,
        codexIdentityDidResolve: (@MainActor @Sendable (_ providerID: String, _ identityKey: String) -> Void)? = nil
    ) -> ProviderRuntimeAssembly {
        let environmentReady: Bool
        if let shellEnvironmentReady {
            environmentReady = shellEnvironmentReady
        } else {
            // Provider keys exported in a shell profile must resolve for Finder-launched app builds,
            // while discovery needs shell-only home overrides to distinguish the default from extras.
            LoginShellEnvironment.shared.prewarm()
            environmentReady = LoginShellEnvironment.shared.waitForCapture(timeout: 0.5)
        }

        let instancesStore = ProviderInstancesStore(defaults: defaults)
        let codexIdentityCache = CodexHomeIdentityCache(defaults: defaults)
        let discovered = ProviderInstanceLaunchGate.discover(shellEnvironmentReady: environmentReady) {
            if let discovery {
                return discovery(codexIdentityCache)
            }
            return ProviderInstanceDiscovery(codexIdentityCache: codexIdentityCache).run()
        }

        // Folded/default findings still carry identity corrections for an existing anchored record.
        let foldedUpdates = discovered.foldedInstancesForReconciliation.filter { finding in
            guard let findingAnchor = finding.anchorPath else { return false }
            let canonicalAnchor = ProviderInstanceID.canonicalHomePath(findingAnchor)
            return instancesStore.records.contains { record in
                record.baseProviderID == finding.baseProviderID
                    && record.anchorPath.map(ProviderInstanceID.canonicalHomePath) == canonicalAnchor
            }
        }
        let records = instancesStore.reconcile(
            with: discovered.instances,
            anchoredUpdates: foldedUpdates + discovered.defaultAnchoredInstancesForReconciliation
        )

        // A persisted instance can temporarily name the current default account after a swap. Suppress
        // it until identities prove the cards are distinct; one account must never appear twice.
        let visibleRecords = records.filter { record in
            if discovered.basesWithUnreadableDefault.contains(record.baseProviderID) {
                AppLog.info(
                    .config,
                    "instance \(record.id) suppressed: default \(record.baseProviderID) identity unreadable this launch"
                )
                return false
            }
            if record.baseProviderID == "codex",
               let anchorPath = record.anchorPath,
               discovered.unverifiedCodexKeyringHomes.contains(
                   ProviderInstanceID.canonicalHomePath(anchorPath)
               )
            {
                AppLog.info(
                    .config,
                    "instance \(record.id) suppressed: its keyring identity binding is unverified this launch"
                )
                return false
            }
            let isCurrentDefault = discovered.defaultIdentityKeys[record.baseProviderID]?
                .contains(record.identityKey) ?? false
            if isCurrentDefault {
                AppLog.info(
                    .config,
                    "instance \(record.id) matches the current default login; showing it on the default card only"
                )
            }
            return !isCurrentDefault
        }

        for record in records {
            let suppressed = visibleRecords.contains(record) ? "" : " (suppressed this launch)"
            AppLog.info(
                .config,
                "instance registry: \(record.id) ordinal=\(record.ordinal) kind=\(record.kind.rawValue) anchor=\(ProviderInstanceID.logPath(record.anchorPath))\(suppressed)"
            )
        }

        var codexRelatedLogRootsByHome: [String: [URL]] = [:]
        for roots in discovered.codexLogRootsByIdentityKey.values {
            let uniqueRoots = roots.reduce(into: [URL]()) { result, root in
                let canonicalRoot = ProviderInstanceID.canonicalHomePath(root.path)
                guard !result.contains(where: {
                    ProviderInstanceID.canonicalHomePath($0.path) == canonicalRoot
                }) else { return }
                result.append(URL(fileURLWithPath: canonicalRoot))
            }
            for root in uniqueRoots {
                codexRelatedLogRootsByHome[
                    ProviderInstanceID.canonicalHomePath(root.path)
                ] = uniqueRoots
            }
        }

        let defaultClaudeIdentityKey = discovered.defaultIdentityKeys["claude"]?.first
        let instanceContext = ProviderInstanceContext(
            records: visibleRecords,
            coworkRootsByInstanceID: visibleRecords.reduce(into: [:]) { map, record in
                guard record.baseProviderID == "claude",
                      let roots = discovered.coworkRootsByIdentityKey[record.identityKey]
                else { return }
                // Card ids survive a re-login, so route roots through the reconciled record instead of
                // recomputing an id from the current identity and potentially losing those roots.
                map[record.id] = roots
            },
            defaultClaudeAdditionalLogRoots: defaultClaudeIdentityKey.flatMap {
                discovered.coworkRootsByIdentityKey[$0]
            } ?? [],
            defaultClaudeLogRoots: discovered.defaultClaudeLogRoots,
            defaultClaudeCoworkRoots: discovered.defaultClaudeCoworkRoots,
            codexRelatedLogRootsByHome: codexRelatedLogRootsByHome,
            claudeSwapTimeline: discovered.claudeSwapTimeline,
            claudeSharedHomeRoots: discovered.claudeSharedHomeRoots,
            defaultClaudeIdentityKey: defaultClaudeIdentityKey
        )

        let providers = ProviderCatalog.make(
            defaults: defaults,
            instanceContext: instanceContext,
            codexIdentityCache: codexIdentityCache,
            codexIdentityDidResolve: codexIdentityDidResolve
        )

        // Card → account identity for history ownership. Ambiguous defaults publish no identity.
        var providerIdentityKeys: [String: String] = [:]
        for (base, keys) in discovered.defaultIdentityKeys where keys.count == 1 {
            providerIdentityKeys[base] = keys.first
        }
        for record in visibleRecords {
            providerIdentityKeys[record.id] = record.identityKey
        }

        return ProviderRuntimeAssembly(
            providers: providers,
            providerIdentityKeys: providerIdentityKeys,
            codexIdentityCache: codexIdentityCache,
            unverifiedCodexKeyringHomes: discovered.unverifiedCodexKeyringHomes
        )
    }

    /// Discovery keeps an unverified keyring-backed Codex card hidden, then this retained task performs
    /// one account-scoped read so the next process can place it safely.
    func startCodexIdentityWarmTask() -> Task<Void, Never>? {
        guard !unverifiedCodexKeyringHomes.isEmpty else { return nil }
        let orderedHomes = unverifiedCodexKeyringHomes.sorted()
        let identityCache = codexIdentityCache
        return Task.detached(priority: .utility) {
            for home in orderedHomes {
                guard !Task.isCancelled else { return }
                let store = CodexAuthStore(
                    scope: .home(path: home),
                    identityCache: identityCache
                )
                if store.loadKeychainAuth() == nil {
                    AppLog.warn(
                        .keychain,
                        "could not warm one unverified Codex keyring identity; affected account cards will stay conservatively hidden"
                    )
                }
            }
        }
    }
}
