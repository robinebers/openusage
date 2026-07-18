import Foundation

/// The launch-time account pass: read which account is signed in at each family's default home,
/// reconcile the account registry, and expose the per-card identity map that the snapshot cache's
/// account stamp and the bare-id resolver consume. Runs once per launch (app) or per invocation
/// (one-shot CLI); a mid-run swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. Phase 1 observes only default
    /// homes, so the keys are the bare family ids; a family whose identity didn't resolve is absent.
    let identityKeysByCard: [String: String]
    /// The family ids whose default login resolved this launch — the resolver's badge-holder input.
    var resolvedFamilyIDs: Set<String> { Set(identityKeysByCard.keys) }

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports).
    static func make(defaults: UserDefaults = .standard, waitsForLoginShell: Bool) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, whose layering (process environment, live login-shell
        // capture, persisted shell-environment snapshot) guarantees identity and usage resolve the
        // same homes. The one unreadable state is a genuinely FIRST Finder/Dock launch: capture
        // still cold and no snapshot persisted yet — an exported override would be invisible, so
        // skip the pass rather than misread it as "no override".
        if waitsForLoginShell,
           !LoginShellEnvironment.shared.capturedSuccessfully,
           ShellEnvironmentSnapshotStore.launchSnapshot == nil {
            AppLog.info(.config, "account identity read skipped: login shell cold and no shell-environment snapshot exists yet")
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: ProviderAccountsStore(defaults: defaults)
        )
    }

    /// The environment-independent core, separated so tests inject a fixed observer and scratch store.
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.Observation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", observer.observeClaude()),
            ("codex", observer.observeCodex()),
        ]
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.Observation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        accountsStore.reconcile(with: observations)
        return ProviderAccountAssembly(identityKeysByCard: identityKeys)
    }
}
