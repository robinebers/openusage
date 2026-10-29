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
    let telemetry: TelemetryRecorder
    @ObservationIgnored private var providers: [AccountProviderRuntime]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let claudeSessions: ClaudeSessions
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
        let claudeSessions = ClaudeSessions(defaults: defaults)
        self.claudeSessions = claudeSessions
        let providers = ProviderCatalog.make(
            accounts: accounts.accounts, vault: accounts.credentialVault, http: http, claudeSessions: claudeSessions
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
        if runtime.account.organization == nil,
           let existing = accounts.account(kind: runtime.account.kind, signedInAs: credential), existing.id != runtime.account.id {
            throw ProviderError.unavailable("This account is already added as \(existing.label).")
        }
        do {
            try await runtime.validate(credential)
        } catch ProviderError.signInExpired(let kind) {
            throw ProviderError.unavailable("\(kind.displayName) rejected the API key.")
        } catch ProviderError.keyRejected(let message) {
            throw ProviderError.unavailable(message)
        }
        try accounts.replaceCredential(credential, for: runtime.account.id)
        await dataStore.refresh(providerID: providerID, force: true, rereadHourly: true)
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
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
        let previousIDs = Set(providers.map(\.provider.id))
        providers = ProviderCatalog.make(
            accounts: accounts.accounts,
            vault: accounts.credentialVault,
            http: http,
            claudeSessions: claudeSessions,
            reusing: providers
        )
        let registry = WidgetRegistry.from(providers)
        layout.apply(registry: registry)
        if let id = popover.customizeProviderID, registry.provider(id: id) == nil {
            popover.customizeProviderID = nil
        }
        dataStore.apply(providers: providers, registry: registry)
        for id in providers.map(\.provider.id) where !previousIDs.contains(id) {
            Task { await dataStore.refresh(providerID: id, force: true) }
        }
    }
}
