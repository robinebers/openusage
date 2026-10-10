import Foundation
import Observation

/// The welcome screen exists before AppContainer, account discovery, or automatic refreshes.
@MainActor @Observable
final class FirstLaunchSetup {
    static let pendingKey = "openusage.onboarding.connectionPending"
    static func needsSetup(isFreshInstall: Bool, defaults: UserDefaults = .standard) -> Bool {
        if isFreshInstall {
            defaults.set(true, forKey: pendingKey)
            return true
        }
        if let enabled = ProviderEnablementStore(defaults: defaults).enabledIDs {
            return enabled.isEmpty
        }
        return defaults.bool(forKey: pendingKey)
    }

    struct Choice: Identifiable {
        let provider: Provider
        var id: String { provider.id }
        var detected = false
        var needsAccess = false
        var connecting = false
        var connected = false
        var error: String?
        var usageUnavailable = false
    }

    private let providers: [ProviderRuntime]
    private let makeContainer: (@MainActor (Set<String>) async -> AppContainer)?
    private(set) var preparedContainer: AppContainer?
    private(set) var firstSnapshots: [String: ProviderSnapshot] = [:]
    private(set) var choices: [Choice]
    var selectedIDs: Set<String> = []
    var showAll = false
    private(set) var isDetecting = true
    private(set) var isConnecting = false
    private(set) var hasAttemptedConnection = false
    var visibleChoices: [Choice] { choices.filter { showAll || $0.detected } }
    var connectedIDs: Set<String> { Set(choices.filter(\.connected).map(\.id)) }
    var hasFailures: Bool { choices.contains { $0.error != nil } }

    init(providers: [ProviderRuntime],
         makeContainer: (@MainActor (Set<String>) async -> AppContainer)? = nil) {
        self.providers = providers
        self.makeContainer = makeContainer
        self.choices = providers.map { Choice(provider: $0.provider) }
    }

    func detect() async {
        let tasks = providers.map { provider in
            Task { @MainActor in
                let access = KeychainAccessContext(mode: .discovery)
                let usable = await KeychainAccessContext.$current.withValue(access) {
                    await provider.hasLocalCredentials()
                }
                return (provider.provider.id, usable || access.needsPermission, access.needsPermission)
            }
        }
        for task in tasks {
            let (id, detected, needsAccess) = await task.value
            guard !Task.isCancelled else { return }
            if let index = choices.firstIndex(where: { $0.id == id }) {
                choices[index].detected = detected
                choices[index].needsAccess = needsAccess
                if detected { selectedIDs.insert(id) }
            }
        }
        isDetecting = false
        AppLog.info(.config, "welcome: detected \(selectedIDs.count) providers without requesting Keychain access")
    }

    func connectSelected() async {
        guard !isConnecting, !isDetecting else { return }
        isConnecting = true
        hasAttemptedConnection = true
        defer { isConnecting = false }
        if preparedContainer == nil, let makeContainer {
            preparedContainer = await makeContainer(selectedIDs)
        }
        let runtimes = preparedContainer?.providerRuntimes ?? providers
        // Account discovery happens once. The dashboard receives these exact runtimes and results.
        for index in choices.indices {
            let family = choices[index].id
            guard !Task.isCancelled else { return }
            guard selectedIDs.contains(family),
                  !choices[index].connected || choices[index].usageUnavailable else { continue }
            choices[index].connecting = true
            choices[index].error = nil
            choices[index].usageUnavailable = false
            var accessFailed = false
            for provider in runtimes where ProviderAccountID.family(of: provider.provider.id) == family {
                let access = KeychainAccessContext(mode: .interactive)
                let snapshot = await KeychainAccessContext.$current.withValue(access) {
                    await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
                }
                guard !Task.isCancelled else { return }
                firstSnapshots[provider.provider.id] = snapshot
                preparedContainer?.dataStore.adoptFirstRefresh(snapshot)
                if let category = snapshot.errorCategory {
                    if Self.isUsageFailure(category) {
                        choices[index].usageUnavailable = true
                        choices[index].error = "Enabled · Usage temporarily unavailable"
                    } else {
                        accessFailed = true
                        if access.needsPermission {
                            choices[index].error = "Access wasn't granted. You can retry or skip for now."
                        } else if case .badge(_, let message, _, _) = snapshot.lines.first {
                            choices[index].error = message
                        } else {
                            choices[index].error = "Couldn't connect. Try again when you're ready."
                        }
                    }
                }
            }
            choices[index].connecting = false
            choices[index].connected = !accessFailed
            choices[index].needsAccess = accessFailed
            AppLog.info(.config, "welcome: \(family) enabled=\(!accessFailed), usageUnavailable=\(choices[index].usageUnavailable)")
        }
    }

    private static func isUsageFailure(_ category: ErrorCategory) -> Bool {
        switch category {
        case .network, .http5xx, .rateLimited, .decoding: true
        default: false
        }
    }
}
