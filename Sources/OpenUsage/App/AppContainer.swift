import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    let accounts: AccountStore
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let renaming: AccountRenameStore
    let popover = PopoverState()
    let hideFromScreenShare: HideFromScreenShareSetting
    let telemetry: TelemetryRecorder
    let hubs: CLIProxyHubSync
    @ObservationIgnored private var providers: [AccountProviderRuntime]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let claudeSessions: ClaudeSessions
    @ObservationIgnored private let hubGate = CLIProxyHubGate()
    @ObservationIgnored private let quotaNotifications = QuotaNotificationEvaluator()

    init(
        accounts: AccountStore = AccountStore(),
        defaults: UserDefaults = .standard,
        http: any HTTPClient = URLSessionHTTPClient(),
        telemetry sink: any TelemetrySink,
        telemetryDefaults: UserDefaults
    ) {
        self.accounts = accounts
        self.http = http
        self.defaults = defaults
        self.hideFromScreenShare = HideFromScreenShareSetting(defaults: defaults)
        let claudeSessions = ClaudeSessions(defaults: defaults)
        self.claudeSessions = claudeSessions
        let providers = ProviderCatalog.make(
            accounts: accounts.accounts, vault: accounts.credentialVault, http: http, hubGate: hubGate, claudeSessions: claudeSessions
        )
        let registry = WidgetRegistry.from(providers)
        let layout = LayoutStore(registry: registry, defaults: defaults)
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults
        )
        self.providers = providers
        self.layout = layout
        self.dataStore = dataStore
        self.renaming = AccountRenameStore(accounts: accounts)
        self.hubs = CLIProxyHubSync(accounts: accounts, client: CLIProxyHubClient(http: http, gate: hubGate))
        let telemetry = TelemetryRecorder(
            sink: sink,
            defaults: telemetryDefaults,
            snapshot: { [accounts, layout] in
                var kinds: [String] = []
                for kind in accounts.accounts.map(\.kind.rawValue) where !kinds.contains(kind) {
                    kinds.append(kind)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: kinds,
                    enabledMetricIDs: layout.visibleDescriptors.map(\.kindScopedKey),
                    pinnedMetricIDs: layout.pinnedMetricIDs.compactMap { layout.registry.descriptor(id: $0)?.kindScopedKey }.sorted()
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] kind, result, manual in
            telemetry?.record(providerID: kind.rawValue, result: result, manual: manual)
        }
        self.telemetry = telemetry
        accounts.didChange = { [weak self] in self?.syncAccounts() }
    }

    deinit {
        refreshTask?.cancel()
    }

    func resetClaim(for providerID: String) -> ResetClaimService? {
        guard let runtime = providers.first(where: { $0.provider.id == providerID }) else { return nil }
        return runtime.resetClaimService { [dataStore] in
            await dataStore.refresh(providerID: providerID, force: true)
        }
    }

    /// Saves a pasted key only once the account's usage read accepts it and the account is still added,
    /// so a refused key never replaces one that works and a removed account's key never comes back.
    func replaceKey(_ key: String, for providerID: String) async throws {
        guard let runtime = providers.first(where: { $0.provider.id == providerID }) else { return }
        let credential = AccountCredential.apiKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        if let existing = accounts.account(kind: runtime.account.kind, organization: runtime.account.organization, signedInAs: credential),
           existing.id != runtime.account.id {
            throw ProviderError.unavailable("This account is already added as \(existing.label).")
        }
        do {
            try await runtime.validate(credential)
        } catch ProviderError.keyRejected(let message) {
            throw ProviderError.unavailable(message)
        }
        try accounts.replaceCredential(credential, for: runtime.account.id)
        await dataStore.refresh(providerID: providerID, force: true, rereadHourly: true)
    }

    /// Saves a hub's new management key once the hub accepts it, then refreshes the hub's accounts.
    func replaceHubKey(_ key: String, for hubID: UUID) async throws {
        try await hubs.replaceKey(key, for: hubID)
        let ids = Set(accounts.accounts(onHub: hubID).map(\.cardID))
        await dataStore.refresh(providerIDs: providers.map(\.provider.id).filter(ids.contains), force: true)
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                await hubs.syncDue()
                await dataStore.refreshAll()
                await quotaNotifications.evaluate(
                    layout.visibleDescriptors,
                    data: dataStore.data(for:),
                    isOn: { [defaults] in defaults.bool(forKey: $0.settingKey) },
                    now: Date(),
                    providerName: { [layout] id in layout.provider(id: id)?.fullName ?? id }
                )
                telemetry.tick()
                let next = ContinuousClock.now + .seconds(RefreshSetting.interval)
                try? await Task.sleep(until: next - .seconds(RefreshSetting.interval / 2), clock: .continuous)
                guard !Task.isCancelled else { return }
                await dataStore.refreshHourlyReads()
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    private func syncAccounts() {
        let previous = providers.map { ObjectIdentifier($0) }
        providers = ProviderCatalog.make(
            accounts: accounts.accounts,
            vault: accounts.credentialVault,
            http: http,
            hubGate: hubGate,
            claudeSessions: claudeSessions,
            reusing: providers
        )
        let registry = WidgetRegistry.from(providers)
        layout.apply(registry: registry)
        if let id = popover.customizeProviderID, registry.provider(id: id) == nil {
            popover.customizeProviderID = nil
        }
        dataStore.apply(providers: providers, registry: registry)
        for runtime in providers where !previous.contains(ObjectIdentifier(runtime)) {
            Task { await dataStore.refresh(providerID: runtime.provider.id, force: true) }
        }
    }
}
