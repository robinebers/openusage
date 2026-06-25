import Foundation
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Providers settings tab drives it.
    let enablement: ProviderEnablementStore
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>

    init() {
        let providers: [ProviderRuntime] = [
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider()
        ]
        let registry = WidgetRegistry.from(providers)
        let enablement = ProviderEnablementStore()
        let layout = LayoutStore(
            registry: registry,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } }
        )
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        self.registry = registry
        self.enablement = enablement
        self.layout = layout
        self.dataStore = dataStore
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.providerOrder.filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots
            )
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore)
        localAPI.start()
    }

    deinit { refreshTask.cancel() }

    /// Drives live updates: refresh due providers on launch, then wake for the soonest provider-specific
    /// probe. Each pass honors the cache/backoff, so Codex can be fresh every minute without forcing
    /// Claude/Grok/Cursor/Devin to poll at the same pace.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await dataStore.refreshDueProviders()
                await waitForNextRefresh(dataStore: dataStore)
            }
        }
    }

    /// Sleep until the soonest provider is due, but wake early when the user enables/disables a provider
    /// so a newly-enabled provider is fetched promptly instead of waiting out another provider's cadence.
    /// Each pass still honors the cache and per-provider backoff.
    ///
    /// Deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the firehose
    /// `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes, Sparkle's
    /// update bookkeeping, and unrelated global-domain changes from other processes. Waking on that, with
    /// no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a refresh storm.
    private static func waitForNextRefresh(dataStore: WidgetDataStore) async {
        let nextRefreshAt = dataStore.nextScheduledRefreshDate()
        await withTaskGroup(of: Void.self) { group in
            if let nextRefreshAt {
                group.addTask {
                    let delay = max(0.25, nextRefreshAt.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: ProviderEnablementStore.didChangeNotification) {
                    break
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
