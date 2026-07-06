import Foundation

/// Turns on providers that arrived with an update — but only the ones the user actually has.
///
/// `FirstRunSeeder` handles the very first launch; this is its every-later-launch sibling. It diffs the
/// registry against the store's known-provider set: anything never seen before gets the same local-only
/// `hasLocalCredentials()` probe as first-run detection, and is enabled on a hit. Providers the install
/// has already seen are never touched, so a user's choice to keep one off is never overridden.
///
/// One-shot semantics: new IDs are marked known synchronously, before the probe. A new provider without
/// credentials stays off and is never probed again — enabling it later is the user's call.
@MainActor
enum NewProviderSeeder {
    /// Returns the detection task (for tests to await), or `nil` when there is nothing to do — the
    /// common case: no new providers, or a store still in legacy disabled-list mode (where new providers
    /// default to on already, so there is nothing to detect).
    @discardableResult
    static func reconcileIfNeeded(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never>? {
        guard enablement.enabledIDs != nil else { return nil }

        let currentIDs = Set(providers.map(\.provider.id))
        // An enabled-list store with no known set predates the tracking (an unbundled `swift run`
        // seeded before this shipped — bundled installs get it from the v2 settings migration or
        // `FirstRunSeeder`). Baseline it to the current registry without probing: we can't tell "new"
        // from "user turned it off", so auto-enabling anything here could override a real choice.
        guard !enablement.knownIDs.isEmpty else {
            enablement.registerKnownProviders(currentIDs)
            return nil
        }

        let newIDs = enablement.registerKnownProviders(currentIDs)
        guard !newIDs.isEmpty else { return nil }
        AppLog.info(.config, "new providers since last run: \(newIDs.sorted()); probing local credentials")

        return Task {
            // Same concurrent local-only probe as first-run detection and the Reset All reseed.
            let newProviders = providers.filter { newIDs.contains($0.provider.id) }
            let detected = await FirstRunSeeder.detectLocalProviders(newProviders)
            for id in detected.sorted() {
                // The probe takes a moment; if the user already turned the provider on themselves,
                // leave their toggle alone (setEnabled would be a no-op anyway).
                guard !enablement.isEnabled(id) else { continue }
                AppLog.info(.config, "new provider \(id): credentials detected, enabling")
                enablement.setEnabled(true, for: id)
            }
        }
    }
}
