import Foundation

/// Turns on providers that arrived with an update — but only the ones the user actually has.
///
/// `FirstRunSeeder` handles the very first launch; this is its every-later-launch sibling. It diffs the
/// registry against the store's known-provider set: anything never seen before gets the same local-only
/// `hasLocalCredentials()` probe as first-run detection, and is enabled on a hit. Providers the install
/// has already seen are never touched, so a user's choice to keep one off is never overridden, and a new
/// account of a provider the install already has follows that provider's on/off choice. The probe can
/// wait on a Keychain prompt; a toggle the user makes meanwhile wins, whichever way it went.
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

        let knownFamilies = Set(enablement.knownIDs.map(ProviderAccountID.family(of:)))
        let enabledFamilies = Self.enabledFamilies(enablement, installed: currentIDs)
        let newIDs = enablement.registerKnownProviders(currentIDs)
        let probedIDs = newIDs.filter { id in
            let family = ProviderAccountID.family(of: id)
            return !knownFamilies.contains(family) || enabledFamilies.contains(family)
        }
        guard !probedIDs.isEmpty else { return nil }
        AppLog.info(.config, "new providers since last run: \(probedIDs.sorted()); probing local credentials")
        // The probe can wait on a Keychain prompt. A card the user toggled meanwhile — on, or on and
        // off again — keeps their choice: its revision moved, so the loop below leaves it alone.
        let revisions = enablement.toggleRevisions

        return Task {
            // Same concurrent local-only probe as first-run detection and the Reset All reseed.
            let newProviders = providers.filter { probedIDs.contains($0.provider.id) }
            let detected = await FirstRunSeeder.detectLocalProviders(newProviders)
            // Read again, not reused: the user may have turned the family's last card off while the
            // probe ran, and the family rule holds at the moment a card is turned on.
            let enabledFamilies = Self.enabledFamilies(enablement, installed: currentIDs)
            for id in detected.sorted() {
                let family = ProviderAccountID.family(of: id)
                guard !knownFamilies.contains(family) || enabledFamilies.contains(family),
                      enablement.toggleRevisions[id] == revisions[id]
                else { continue }
                AppLog.info(.config, "new provider \(id): credentials detected, enabling")
                enablement.setEnabled(true, for: id)
            }
        }
    }

    /// The families with an installed card on. Only installed cards count: the enabled id of a Codex
    /// account removed in Customize must not keep the family "on" after the user turned every
    /// remaining card off.
    private static func enabledFamilies(_ enablement: ProviderEnablementStore, installed: Set<String>) -> Set<String> {
        Set((enablement.enabledIDs ?? []).filter { installed.contains($0) }.map(ProviderAccountID.family(of:)))
    }
}
