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
    /// Providers that need a user-supplied API key (OpenRouter today), conforming to `APIKeyManaging`.
    /// Settings ▸ API Keys lists these and writes key changes through the capability. Empty when no
    /// installed provider needs a user key, in which case the section hides itself.
    let apiKeyProviders: [any APIKeyManaging]
    /// Quota pace notification preferences (master + three triggers). Drives the Settings section and is
    /// read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous, opt-out usage telemetry (daily rollups). Exposed so Settings can toggle it and the
    /// app-termination hook can flush any queued events.
    let telemetry: TelemetryRecorder
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>

    init() {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()

        // Default provider order (see AGENTS.md "## Providers"): the three established providers first —
        // Claude, Codex, Cursor — then every other provider alphabetically by display name. This registry
        // order is the default provider order (`LayoutStore.orderedProviderIDs` falls back to it, and
        // `resetToDefault` seeds it), so the dashboard, Customize sections, and the per-provider reset
        // menu all read this way.
        let providers: [ProviderRuntime] = [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(),
            DevinProvider(),
            GrokProvider(),
            OpenRouterProvider()
        ]
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let layout = LayoutStore(
            registry: registry,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings }
        )
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore

        // Anonymous, opt-out usage telemetry (two daily-rollup events). Its state lives in a dedicated
        // UserDefaults suite, kept separate from app settings so the user's opt-out choice and the
        // install id stay independent of any settings change. The snapshot closure reads the live
        // layout/enablement so `app_daily_active` always reflects the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [registry, enablement, layout] in
                // Report the *active* configuration: a metric whose provider is turned off is hidden
                // from the dashboard and menu bar, so exclude it here too — keeping the metric arrays
                // consistent with `enabledProviders` (which is also enablement-filtered).
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: registry.providers.map(\.id).filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.providerOrder.filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots
            )
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on (from Settings), not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit { refreshTask.cancel() }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await dataStore.refreshAll()
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: emits `app_daily_active` once per local day and flushes any
                // prior-day provider rollups. Runs on launch and every interval, so always-running
                // instances still produce a daily-active signal.
                telemetry.tick()
                await waitForNextRefresh()
            }
        }
    }

    /// Sleep for the refresh interval, but wake early when the user enables/disables a provider so a
    /// newly-enabled provider is fetched promptly instead of waiting out the full interval. Each pass still
    /// honors the cache (and the per-provider failure backoff), so an early wake only hits the network for
    /// a provider whose snapshot has actually expired.
    ///
    /// Deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the firehose
    /// `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes, Sparkle's
    /// update bookkeeping, and unrelated global-domain changes from other processes. Waking on that, with
    /// no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a refresh storm.
    private static func waitForNextRefresh() async {
        let interval = RefreshSetting.interval
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(interval))
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
