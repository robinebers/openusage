import Foundation
import Observation

/// The welcome screen exists before AppContainer, account discovery, or automatic refreshes.
@MainActor @Observable
final class FirstLaunchSetup {
    static let pendingKey = "openusage.onboarding.connectionPending"
    static func needsSetup(isFreshInstall: Bool, defaults: UserDefaults = .standard) -> Bool {
        if isFreshInstall { defaults.set(true, forKey: pendingKey) }
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
    }

    private let providers: [ProviderRuntime]
    private(set) var choices: [Choice]
    var selectedIDs: Set<String> = []
    var showAll = false
    private(set) var isDetecting = true
    private(set) var isConnecting = false
    private(set) var hasAttemptedConnection = false
    var visibleChoices: [Choice] { choices.filter { showAll || $0.detected } }
    var connectedIDs: Set<String> { Set(choices.filter(\.connected).map(\.id)) }
    var hasFailures: Bool { choices.contains { $0.error != nil } }

    init(providers: [ProviderRuntime]) {
        self.providers = providers
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
        // Keep permission dialogs in provider order, never fan these operations out.
        for (index, provider) in providers.enumerated() {
            guard !Task.isCancelled else { return }
            guard selectedIDs.contains(provider.provider.id), !choices[index].connected else { continue }
            choices[index].connecting = true
            choices[index].error = nil
            let access = KeychainAccessContext(mode: .interactive)
            let snapshot = await KeychainAccessContext.$current.withValue(access) {
                await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
            }
            choices[index].connecting = false
            guard !Task.isCancelled else { return }
            if snapshot.errorCategory != nil {
                if access.needsPermission {
                    choices[index].error = "Access wasn't granted. You can retry or skip for now."
                } else if case .badge(_, let message, _, _) = snapshot.lines.first {
                    choices[index].error = message
                } else {
                    choices[index].error = "Couldn't connect. Try again when you're ready."
                }
                AppLog.warn(.config, "welcome: connection failed for \(provider.provider.id)")
            } else {
                choices[index].connected = true
                choices[index].needsAccess = false
                AppLog.info(.config, "welcome: connected \(provider.provider.id)")
            }
        }
    }
}
