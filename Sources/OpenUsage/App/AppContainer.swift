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
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    let apiKeyProviders: [any APIKeyManaging]
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous, opt-out usage telemetry (daily rollups). Exposed so Settings can toggle it and the
    /// app-termination hook can flush any queued events.
    let telemetry: TelemetryRecorder
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Extra provider accounts found on this machine and which one each provider card shows. The
    /// header's account picker and Customize's Accounts section both read and drive this.
    let providerAccounts: ProviderAccountsStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write). Shares the Codex provider's auth store and usage client; `nil` only if the Codex
    /// provider were ever removed from the registry. Injected into the view tree via
    /// `\.codexResetClaim`.
    let codexResetClaim: CodexResetClaimService?
    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private let providers: [ProviderRuntime]
    /// The multi-account-capable subset of `providers`, kept for account rediscovery (the post-launch
    /// scan and the manual-refresh interactive one). See `rediscoverAccounts`.
    private let multiAccountProviders: [any MultiAccountProviderRuntime]
    /// The post-launch account scan. `var` only because it captures `self` and so can't be created
    /// until init completes — which also makes it MainActor-isolated and unreachable from the
    /// nonisolated deinit; that's fine: it holds `self` weakly and one scan finishes in milliseconds,
    /// so there is nothing long-lived to cancel.
    private var accountDiscoveryTask: Task<Void, Never>?
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// The fresh-install credential-detection pass (see `FirstRunSeeder`); `nil` on every later launch.
    private let seedTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()

        let providers = ProviderCatalog.make()
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()

        // Multi-account: launch builds runtimes from the PERSISTED account records only — no
        // discovery I/O on the startup path (a keychain read here once froze launch behind a hidden
        // ACL dialog). The actual scan runs just after init in `rediscoverAccounts`, which reconciles
        // the records and registers runtimes for anything new, live. Everything else (layout,
        // enablement, metric ids) stays per-provider — the account picker only swaps which login's
        // data fills the card.
        let providerAccounts = ProviderAccountsStore()
        var accountRuntimes: [AccountRuntime] = []
        for runtime in providers {
            let providerID = runtime.provider.id
            accountRuntimes.append(AccountRuntime(providerID: providerID, accountKey: providerID, runtime: runtime))
            guard let multi = runtime as? any MultiAccountProviderRuntime else { continue }
            for record in providerAccounts.accounts(for: providerID) {
                accountRuntimes.append(AccountRuntime(
                    providerID: providerID,
                    accountKey: record.accountKey,
                    runtime: multi.makeAccountRuntime(for: record)
                ))
            }
        }

        let layout = LayoutStore(
            registry: registry,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            accountRuntimes: accountRuntimes,
            selectedAccountKey: { [providerAccounts] in providerAccounts.selectedAccountKey(for: $0) },
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings }
        )
        // Picking another account swaps the card (and its menu-bar pins) to that login's snapshot,
        // then fetches it if the cache has nothing fresh.
        providerAccounts.onSelectionChange = { [weak dataStore] providerID in
            dataStore?.applySelection(providerID: providerID)
        }
        self.multiAccountProviders = providers.compactMap { $0 as? any MultiAccountProviderRuntime }
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Cursor right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = NewProviderSeeder.reconcileIfNeeded(
            providers: providers,
            enablement: enablement
        )
        self.providers = providers
        self.onboarding = onboarding
        self.providerAccounts = providerAccounts
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore

        // The resets popover's claim service, sharing the Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. The auth store is resolved per
        // claim through the account selection, so the claim always targets the account whose resets
        // the popover is showing. A successful claim forces a Codex refresh so the meters and credit
        // count reconcile before the popover shows its result. The forced refresh returns `.skipped`
        // when another refresh already owns the provider — and that in-flight probe may carry
        // *pre-claim* usage — so retry until this refresh actually runs (bounded; the racing probe
        // finishes in seconds).
        let codexRuntimesByKey: [String: CodexProvider] = Dictionary(
            uniqueKeysWithValues: accountRuntimes.compactMap { entry in
                (entry.runtime as? CodexProvider).map { (entry.accountKey, $0) }
            }
        )
        self.codexResetClaim = codexRuntimesByKey["codex"].map { codex in
            CodexResetClaimService(
                authStore: { [providerAccounts] in
                    let key = providerAccounts.selectedAccountKey(for: codex.provider.id)
                    return (codexRuntimesByKey[key] ?? codex).authStore
                },
                usageClient: codex.usageClient,
                refreshAfterClaim: { [weak dataStore] in
                    // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                    // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                    // common race (the periodic timer's probe) clears in a couple of seconds; the
                    // pathological one keeps the popover's honest "Resetting…" up rather than showing
                    // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                    // too — a transient flake right after the claim must not strand pre-claim meters
                    // behind a success banner — before giving up loudly (the provider error already
                    // shows on the card, so the staleness isn't silent).
                    var failures = 0
                    for attempt in 0..<45 {
                        guard let dataStore else { return }
                        switch await dataStore.refresh(providerID: codex.provider.id, force: true) {
                        case .refreshed, .cacheHit, .backedOff:
                            return
                        case .failed:
                            failures += 1
                            guard failures < 3 else {
                                AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                                return
                            }
                            try? await Task.sleep(for: .seconds(2))
                        case .skipped:
                            AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
                }
            )
        }

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
        self.transparency = PopoverTransparencyStore()
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots,
                limitDescriptors: registry.limitDescriptorsByProvider,
                errors: dataStore.providerErrors
            )
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
        // The launch account scan, right after init and OFF the startup path (see the multi-account
        // note above). Never interactive: a keychain that would need a dialog simply yields nothing
        // until the user's manual refresh grants access.
        accountDiscoveryTask = Task { [weak self] in
            await self?.rediscoverAccounts(allowInteraction: false)
        }
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
    }

    /// The user's explicit "Refresh now" (⌘R / the footer button): re-scan for provider accounts
    /// WITH keychain interaction allowed — this is the one moment a one-time ACL dialog (Claude
    /// Desktop's Safe Storage) may appear, per the manual-refresh-only rule — then force-refresh
    /// every provider.
    func refreshNow() async {
        await rediscoverAccounts(allowInteraction: true)
        await dataStore.refreshAll(force: true)
    }

    /// Discover extra accounts for every multi-account provider, reconcile them into the persisted
    /// records, and register a runtime for anything new — so a found account is usable immediately,
    /// not on the next relaunch. Runs post-launch (never interactive) and on every manual refresh
    /// (interactive, so the Safe Storage grant can happen).
    private func rediscoverAccounts(allowInteraction: Bool) async {
        for multi in multiAccountProviders {
            let providerID = multi.provider.id
            let known = Set(providerAccounts.accounts(for: providerID).map(\.id))
            let records = providerAccounts.reconcile(
                providerID: providerID,
                discovered: multi.discoverExtraAccounts(allowInteraction: allowInteraction)
            )
            for record in records where !known.contains(record.id) {
                dataStore.registerAccountRuntime(AccountRuntime(
                    providerID: providerID,
                    accountKey: record.accountKey,
                    runtime: multi.makeAccountRuntime(for: record)
                ))
            }
        }
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    ///
    /// Between passes the loop sleeps via `RefreshWakeSignal`, which wakes it early when the user
    /// enables/disables a provider so a newly-enabled provider is fetched promptly instead of waiting out
    /// the full interval. The signal subscribes BEFORE the first pass and buffers, so an enablement change
    /// landing while a pass is still running (first-run credential detection, `NewProviderSeeder`, the
    /// Customize "Reset All" reseed — all of which typically finish faster than the network fetches) is
    /// never lost. Each pass still honors the cache (and the per-provider failure backoff), so an early
    /// wake only hits the network for a provider whose snapshot has actually expired.
    ///
    /// The wake is deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the
    /// firehose `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes,
    /// Sparkle's update bookkeeping, and unrelated global-domain changes from other processes. Waking on
    /// that, with no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a
    /// refresh storm.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal()
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
                await wakeSignal.waitForWake(timeout: RefreshSetting.interval)
            }
        }
    }
}
