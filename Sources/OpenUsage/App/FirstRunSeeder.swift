import Foundation

/// Local credential detection shared by the welcome screen, `NewProviderSeeder`, and the Customize
/// "Reset All" reseed. The first launch itself is the welcome screen (`FirstLaunchSetup`); this type no
/// longer seeds fresh installs.
@MainActor
enum FirstRunSeeder {
    /// The established providers (see AGENTS.md "## Providers"), shown when detection finds nothing.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex", "cursor"]

    /// Re-runs local detection on demand for the Customize "Reset All" action. Unlike update-time
    /// seeding, this is a deliberate user reset, so it *does* overwrite the current
    /// on/off choices: it snaps the enabled set to the Claude/Codex/Cursor fallback synchronously (so the
    /// dashboard reflects the reset without waiting on the probe), then replaces it with exactly the
    /// providers detected on this machine once the local credential probe finishes — keeping the fallback
    /// when nothing is detected. A toggle the user flips during the (brief, local-only) probe still wins.
    /// Returns the detection task so tests and callers can await it.
    @discardableResult
    static func reseed(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never> {
        let fallback = fallbackProviderIDs.intersection(Set(providers.map(\.provider.id)))
        enablement.seedEnabledProviders(fallback)
        AppLog.info(.config, "reset all: seeded providers \(fallback.sorted()); re-probing local credentials")
        return Task {
            let detected = await detectLocalProviders(providers)
            AppLog.info(.config, "reset all: detected credentials for \(detected.sorted())")
            guard enablement.enabledIDs == fallback, !detected.isEmpty else { return }
            enablement.seedEnabledProviders(detected)
        }
    }

    /// Local-only credential probe across every provider: the set whose `hasLocalCredentials()` (config
    /// files/keychain, never the network) reports a login on this machine, without showing any Keychain
    /// prompt. Shared by the welcome screen, `NewProviderSeeder`, and Reset All.
    ///
    /// Probes run concurrently — the same MainActor-safe fan-out as `WidgetDataStore.refreshAll` (one
    /// `Task {}` per provider; the overlap happens at the off-main-actor loads inside each probe). A
    /// single probe can shell out to `security`/`sqlite3` with waits of up to ~5s, so probing the whole
    /// registry sequentially made detection take the *sum* of those waits — long enough that detected
    /// providers visibly trickled in on first launch.
    static func detectLocalProviders(_ providers: [ProviderRuntime]) async -> Set<String> {
        let probes = providers.map { provider in
            (provider.provider.id, Task {
                // Prompts stay off. An item macOS won't hand over until the user approves it is still
                // a login on this Mac; connecting the provider asks for that approval.
                let access = KeychainAccessContext(allowsInteraction: false)
                let found = await KeychainAccessContext.$current.withValue(access) {
                    await provider.hasLocalCredentials()
                }
                return found || access.refused == .permissionNeeded
            })
        }
        var detected = Set<String>()
        for (id, probe) in probes where await probe.value {
            detected.insert(id)
        }
        return detected
    }
}
