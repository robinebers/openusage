#if OPENUSAGE_DEVELOPMENT
import Foundation

@MainActor
enum DemoSession {
    static func requested(bundleIdentifier: String?, arguments: [String]) throws -> Bool {
        let wantsDemo = arguments.contains(DevelopmentDataMode.demoArgument)
        guard bundleIdentifier == DevelopmentDataMode.demoBundleID else {
            guard !wantsDemo else { throw unavailable("Sample Data requires the isolated development demo app.") }
            return false
        }
        guard wantsDemo else { throw unavailable("Open Sample Data from the development app’s settings.") }
        return true
    }

    /// The domain name is fixed so this reset can never clear a normal app's accounts or settings.
    static func makeContainer(defaults: UserDefaults, resetDomain: String, now: Date = Date()) throws -> AppContainer {
        guard resetDomain == DevelopmentDataMode.demoBundleID else {
            throw unavailable("Sample Data cannot reset settings outside its isolated demo app.")
        }
        defaults.removePersistentDomain(forName: resetDomain)
        let accounts = DemoFixtures.accounts(at: now)
        defaults.set(try JSONEncoder().encode(accounts), forKey: AccountStore.storageKey)
        defaults.set(try JSONEncoder().encode(DemoFixtures.hubs()), forKey: AccountStore.hubsStorageKey)
        let snapshots = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.cardID, DemoFixtures.snapshot(for: $0, at: now))
        })
        ProviderSnapshotCache(userDefaults: defaults).save(snapshots)
        let store = AccountStore(defaults: defaults, vault: DemoCredentialVault(), hubKeys: DemoHubKeyVault())
        let container = AppContainer(
            accounts: store, defaults: defaults, http: DemoHTTPClient(),
            telemetry: DemoTelemetrySink(), telemetryDefaults: defaults,
            runtimeFactory: { DemoProviderRuntime.make(accounts: $0, existing: $1) },
            hubsEnabled: false
        )
        for provider in container.layout.registry.providers.prefix(2) {
            if let metric = container.layout.registry.descriptors(for: provider.id).first {
                container.layout.setMetric(metric.id, pinned: true)
            }
        }
        AppLog.info(.lifecycle, DemoFixtures.marker)
        return container
    }

    private static func unavailable(_ message: String) -> ProviderError {
        AppLog.error(.lifecycle, message)
        return .unavailable(message)
    }
}
#endif
