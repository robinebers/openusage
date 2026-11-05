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
            accounts: accounts.accounts, vault: accounts.credentialVault, hubKeys: accounts.hubKeys, http: http, hubGate: hubGate,
            claudeSessions: claudeSessions
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
                TelemetryConfigSnapshot(
                    accounts: accounts.accounts,
                    enabledMetricIDs: layout.visibleDescriptors.map(\.kindScopedKey)
                )
            }
        )
        self.telemetry = telemetry
        accounts.didChange = { [weak self] in self?.syncAccounts() }
    }

    deinit {
        refreshTask?.cancel()
    }

    func resetClaim(for providerID: String) -> ResetClaimService? {
        guard let runtime = providers.first(where: { $0.provider.id == providerID }) else { return nil }
        let rereadsResets = runtime.account.kind == .zai
        return runtime.resetClaimService { [dataStore] in
            await dataStore.refresh(providerID: providerID, force: true, rereadHourly: rereadsResets)
        }
    }

    /// Saves a pasted key only once the account's usage read accepts it and the account is still added,
    /// so a refused key never replaces one that works and a removed account's key never comes back.
    func replaceKey(_ key: String, for providerID: String) async throws {
        try await replaceCredential(.apiKey(key.trimmingCharacters(in: .whitespacesAndNewlines)), for: providerID)
    }

    /// Keeps the account, its name and its place: only the sign-in changes, once its usage read works.
    func replaceCredential(_ credential: AccountCredential, for providerID: String) async throws {
        guard let runtime = providers.first(where: { $0.provider.id == providerID }) else { return }
        let account = runtime.account
        if case .oauth = credential, let signedIn = credential.identity,
           let saved = (try? accounts.credential(for: account.id))?.identity, saved != signedIn {
            throw ProviderError.unavailable("That's a different account. Sign in to this one, or use Add New Account.")
        }
        try accounts.checkForDuplicate(credential, kind: account.kind, organization: account.organization, excluding: account.id)
        // The new sign-in reads into its own runtime and vault: the previous sign-in's history and plan
        // can't be reused, and a refused token can't fall back on the stored one.
        let provisional = ProvisionalCredentialVault(credential)
        let replacement = AccountProviderRuntime(account: account, vault: provisional, http: runtime.http, claudeSessions: claudeSessions)
        replacement.isCheckingNewSignIn = true
        let snapshot: ProviderSnapshot
        do {
            snapshot = try await replacement.readSnapshot(using: credential)
        } catch ProviderError.keyRejected(let message) {
            throw ProviderError.unavailable(message)
        }
        try Task.checkCancellation()
        await runtime.stopRenewals()
        do {
            try Task.checkCancellation()
            guard let index = providers.firstIndex(where: { $0.account.id == account.id }) else { return }
            guard providers[index] === runtime else {
                throw ProviderError.unavailable("This account’s sign-in changed while OpenUsage was checking it. Try again.")
            }
            // A read can renew the sign-in, so what's saved is what the read ended on.
            try accounts.replaceCredential(provisional.load(account.id) ?? credential, for: account.id)
            replacement.adopt(accounts.credentialVault)
            replacement.update(runtime.account) // The account may have been renamed during the read.
            providers[index] = replacement
            dataStore.replaceProvider(replacement, snapshot: snapshot)
        } catch {
            runtime.resumeRenewals()
            throw error
        }
    }

    /// Once the new sign-in reads usage, the sign-in sheet closes and the panel shows the Default Tab.
    func signInAgain(_ credential: AccountCredential, for providerID: String) async throws {
        try await replaceCredential(credential, for: providerID)
        popover.showDashboard(on: .preferred(in: defaults))
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
            hubKeys: accounts.hubKeys,
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
