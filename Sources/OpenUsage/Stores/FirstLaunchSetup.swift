import Foundation
import Observation

/// The welcome screen's model. It runs before the dashboard exists: detection only checks what is on
/// this Mac, and Connect refreshes the chosen providers through the dashboard's own data store.
@MainActor @Observable
final class FirstLaunchSetup {
    static let pendingKey = "openusage.onboarding.connectionPending"

    /// Shown until at least one provider is on: an install that skipped setup, or quit mid-welcome,
    /// sees the welcome screen again on the next launch.
    static func needsSetup(defaults: UserDefaults = .standard) -> Bool {
        if let enabled = ProviderEnablementStore(defaults: defaults).enabledIDs {
            return enabled.isEmpty
        }
        return defaults.bool(forKey: pendingKey)
    }

    static func markPending(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }

    static func clearPending(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    enum Connection: Equatable {
        case notChecked, checking, connected
        /// Credentials worked but the usage service didn't answer; the provider stays on and retries
        /// on the normal schedule.
        case usageUnavailable
        case failed(String)
    }

    struct Choice: Identifiable {
        let provider: Provider
        var id: String { provider.id }
        var detected = false
        var connection = Connection.notChecked
    }

    static let accessDeniedMessage = "Access wasn't granted. You can retry or skip for now."

    private let providers: [ProviderRuntime]
    /// Builds the dashboard's data store for the selected provider families, with those families on.
    private let prepare: @MainActor (Set<String>) async -> WidgetDataStore
    private var dataStore: WidgetDataStore?
    private(set) var choices: [Choice]
    var selectedIDs: Set<String> = []
    var showAll = false
    private(set) var isDetecting = true
    private(set) var isConnecting = false
    private(set) var hasAttemptedConnection = false
    var visibleChoices: [Choice] { choices.filter { showAll || $0.detected } }
    var connectedIDs: Set<String> {
        Set(choices.filter { $0.connection == .connected || $0.connection == .usageUnavailable }.map(\.id))
    }
    var hasFailures: Bool {
        choices.contains { if case .failed = $0.connection { true } else { false } }
    }

    init(providers: [ProviderRuntime], prepare: @escaping @MainActor (Set<String>) async -> WidgetDataStore) {
        self.providers = providers
        self.prepare = prepare
        self.choices = providers.map { Choice(provider: $0.provider) }
    }

    func detect() async {
        let detected = await FirstRunSeeder.detectLocalProviders(providers)
        guard !Task.isCancelled else { return }
        for index in choices.indices where detected.contains(choices[index].id) {
            choices[index].detected = true
        }
        selectedIDs = detected
        isDetecting = false
        AppLog.info(.config, "welcome: detected \(detected.sorted()) without Keychain prompts")
    }

    /// Connects the selected providers one at a time, so at most one macOS access dialog is up. A
    /// provider that already connected isn't fetched again on retry.
    func connectSelected() async {
        guard !isConnecting, !isDetecting else { return }
        isConnecting = true
        hasAttemptedConnection = true
        defer { isConnecting = false }
        let store: WidgetDataStore
        if let dataStore { store = dataStore } else {
            store = await prepare(selectedIDs)
            dataStore = store
        }
        for index in choices.indices {
            let family = choices[index].id
            guard selectedIDs.contains(family), choices[index].connection != .connected else { continue }
            guard !Task.isCancelled else { return }
            choices[index].connection = .checking
            choices[index].connection = await connect(family, in: store)
            AppLog.info(.config, "welcome: \(family) → \(choices[index].connection)")
        }
    }

    /// A family connects when every card in it refreshes; the first card that can't use its
    /// credentials decides the failure shown.
    private func connect(_ family: String, in store: WidgetDataStore) async -> Connection {
        var result = Connection.connected
        for id in store.providerIDs(inFamily: family) {
            let outcome = await store.refresh(providerID: id, force: true, allowsKeychainInteraction: true)
            guard outcome != .skipped else {
                AppLog.error(.config, "welcome: \(id) refresh was skipped while connecting")
                return .failed("Couldn't connect. Try again when you're ready.")
            }
            guard let message = store.errorMessage(for: id) else { continue }
            if message == KeychainAccessError.permissionNeeded.errorDescription {
                return .failed(Self.accessDeniedMessage)
            }
            guard store.providerErrorCategories[id]?.isTransient == true else { return .failed(message) }
            result = .usageUnavailable
        }
        return result
    }
}
