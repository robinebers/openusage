import Foundation
import Observation

/// Owns the app's long-lived stores. Accounts are the source of truth: when they change, the container
/// updates the runtimes, layout, and data store in place, synchronously, so the status item, panel, and
/// every other account's data stay as they are.
@MainActor
@Observable
final class AppContainer {
    let accounts: AccountStore
    let notificationSettings: NotificationSettingsStore
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let renaming: AccountRenameStore
    /// Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
    /// Exposed so Settings can toggle extra analytics and termination can flush queued events.
    let telemetry: TelemetryRecorder
    @ObservationIgnored private var providers: [AccountProviderRuntime]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private let http: any HTTPClient

    /// `telemetry` and `telemetryStore` have no defaults on purpose: the PostHog sink starts the
    /// process-global SDK and the production store writes the bundle's telemetry suite, so only the app
    /// entry point supplies them and a test cannot build a container that reports anywhere but its own
    /// fake sink and isolated store.
    init(
        accounts: AccountStore = AccountStore(),
        defaults: UserDefaults = .standard,
        http: any HTTPClient = URLSessionHTTPClient(),
        telemetry sink: any TelemetrySink,
        telemetryStore: TelemetryStore
    ) {
        self.accounts = accounts
        self.http = http
        let providers = ProviderCatalog.make(accounts: accounts.accounts, vault: accounts.credentialVault, http: http)
        let registry = WidgetRegistry.from(providers)
        let notificationSettings = NotificationSettingsStore(defaults: defaults)
        let layout = LayoutStore(registry: registry, defaults: defaults)
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults,
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings }
        )
        self.providers = providers
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore
        self.renaming = AccountRenameStore(accounts: accounts)
        // Ids are kind-scoped (`Account.kindScopedID`), so the events name providers, never accounts.
        let telemetry = TelemetryRecorder(
            sink: sink,
            store: telemetryStore,
            snapshot: { [accounts, layout] in
                var kinds: [String] = []
                for kind in accounts.accounts.map(\.kind.rawValue) where !kinds.contains(kind) {
                    kinds.append(kind)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: kinds,
                    enabledMetricIDs: layout.placed.map { Account.kindScopedID($0.descriptorID) },
                    pinnedMetricIDs: layout.pinnedMetricIDs.map(Account.kindScopedID).sorted()
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, result, manual in
            telemetry?.record(providerID: Account.kindScopedID(providerID), result: result, manual: manual)
        }
        self.telemetry = telemetry
        accounts.didChange = { [weak self] in self?.syncAccounts() }
    }

    deinit {
        refreshTask?.cancel()
    }

    /// The resets popover's claim seam for one account card, or `nil` when the account has no reset claims.
    /// A claim that changed anything refreshes that account, so its meters and reset count catch up.
    func resetClaim(for providerID: String) -> ResetClaimService? {
        guard let runtime = providers.first(where: { $0.provider.id == providerID }) else { return nil }
        return runtime.resetClaimService { [dataStore] in
            await dataStore.refresh(providerID: providerID, force: true)
        }
    }

    /// Runs a pass at launch and then every `RefreshSetting.interval`, so the menu bar keeps updating.
    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                await dataStore.refreshAll()
                await dataStore.evaluateNotifications()
                // Day-rollover beat: emits `app_daily_active` once per local day and flushes prior-day
                // provider rollups while optional analytics are on.
                telemetry.tick()
                try? await Task.sleep(for: .seconds(RefreshSetting.interval))
            }
        }
    }

    /// Runs synchronously inside every `AccountStore` change. A removed account's runtime leaves
    /// `providers` and the data store cancels its refresh before the store's call returns, so a response
    /// that lands later finds no account to commit to.
    private func syncAccounts() {
        let previousIDs = Set(providers.map(\.provider.id))
        providers = ProviderCatalog.make(
            accounts: accounts.accounts,
            vault: accounts.credentialVault,
            http: http,
            reusing: providers
        )
        let registry = WidgetRegistry.from(providers)
        layout.apply(registry: registry)
        dataStore.apply(providers: providers, registry: registry)
        for id in providers.map(\.provider.id) where !previousIDs.contains(id) {
            Task { await dataStore.refresh(providerID: id, force: true) }
        }
    }
}
