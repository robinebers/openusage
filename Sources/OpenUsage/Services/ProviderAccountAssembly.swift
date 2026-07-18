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

    /// `waitsForLoginShell`: the menu-bar app (Finder/Dock launch) inherits no shell exports, so it
    /// briefly waits for the prewarmed login-shell capture. The one-shot CLI runs from a terminal
    /// whose process environment already carries the user's exports — it must not pay that wait.
    static func make(defaults: UserDefaults = .standard, waitsForLoginShell: Bool) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes) — and it must read them through the SAME layering the provider auth stores
        // use (`ProcessEnvironmentReader`), or identity could be read from one home while usage is
        // fetched from another, mis-stamping the shared cache.
        let environment: EnvironmentReading
        if !waitsForLoginShell {
            // Terminal launch: the process environment is the user's real shell environment, and it
            // is exactly what the providers will read. Never pin the snapshot here — its facts could
            // disagree with the environment the auth stores resolve against.
            environment = ProcessEnvironmentReader()
        } else if LoginShellEnvironment.shared.waitForCapture(timeout: 0.5),
                  LoginShellEnvironment.shared.capturedSuccessfully {
            environment = ProcessEnvironmentReader()
        } else if let snapshot = ShellEnvironmentSnapshotStore(defaults: defaults).load() {
            // Slow shell: run on the persisted facts of the last successful capture — shell exports
            // change ~never between launches, and the providers' own reads block until the live
            // capture lands on the same values. Only a genuinely first launch has nothing to fall
            // back on.
            AppLog.debug(.config, "account identity read is using the shell-environment snapshot captured \(snapshot.capturedAt)")
            environment = snapshot.identityEnvironment()
        } else {
            AppLog.info(.config, "account identity read skipped: login shell cold and no shell-environment snapshot exists yet")
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        return make(
            observer: DefaultAccountObserver(environment: environment),
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
