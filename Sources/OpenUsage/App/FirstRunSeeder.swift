import Foundation

/// Fresh-install provider setup and the local credential detection shared with the welcome screen,
/// `NewProviderSeeder`, and the Customize "Reset All" reseed.
///
/// A fresh install starts with no providers on: the welcome screen (`FirstLaunchSetup`) detects the
/// tools on this Mac and turns on the ones the user picks. Existing installs keep their all-on legacy
/// default and are never touched.
@MainActor
enum FirstRunSeeder {
    /// The established providers (see AGENTS.md "## Providers"), shown when detection finds nothing.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex", "cursor"]

    /// The `enabledIDs == nil` guard makes seeding idempotent: an already-seeded store (e.g. an
    /// unbundled `swift run`, which always reports fresh) is never overwritten.
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore
    ) {
        guard isFreshInstall, enablement.enabledIDs == nil else { return }

        // Baseline the known-provider set: everything shipping today has been "seen" by this install,
        // so `NewProviderSeeder` only ever probes providers added in a later release.
        enablement.registerKnownProviders(Set(providers.map(\.provider.id)))
        enablement.seedEnabledProviders([])
        onboarding.markCustomizeHintPending()
        AppLog.info(.config, "first run: no providers on until the welcome screen")
    }

    /// Re-runs first-launch detection on demand for the Customize "Reset All" action. Unlike first-run
    /// and update-time seeding, this is a deliberate user reset, so it *does* overwrite the current
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
    /// files/keychain, never the network) reports a login on this machine. Shared by the welcome screen,
    /// `NewProviderSeeder`, and the Customize "Reset All" reseed so all detect installed tools the same way.
    ///
    /// Probes run concurrently — the same MainActor-safe fan-out as `WidgetDataStore.refreshAll` (one
    /// `Task {}` per provider; the overlap happens at the off-main-actor loads inside each probe). A
    /// single probe can shell out to `security`/`sqlite3` with waits of up to ~5s, so probing the whole
    /// registry sequentially made detection take the *sum* of those waits — long enough that detected
    /// providers visibly trickled in on first launch.
    static func detectLocalProviders(_ providers: [ProviderRuntime]) async -> Set<String> {
        let probes = providers.map { provider in
            (provider.provider.id, Task { await provider.hasLocalCredentials() })
        }
        var detected = Set<String>()
        for (id, probe) in probes where await probe.value {
            detected.insert(id)
        }
        return detected
    }
}
