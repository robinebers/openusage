import Foundation
import Observation

/// The welcome screen's model. Detection only looks at what's on this Mac. Connect turns on the
/// chosen providers and refreshes them one at a time, so at most one macOS access popup is up.
@MainActor @Observable
final class FirstLaunchSetup {
    private static let pendingKey = "openusage.onboarding.welcomePending"

    /// The welcome screen shows on every launch until the user finishes it. An install that already
    /// saved a provider choice skips it: an unbundled `swift run` reports a fresh install every time.
    static func markPending(defaults: UserDefaults = .standard) {
        guard ProviderEnablementStore(defaults: defaults).enabledIDs == nil else { return }
        defaults.set(true, forKey: pendingKey)
    }

    static func isPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingKey)
    }

    static func clearPending(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    enum Connection: Equatable {
        case notChecked, checking, connected
        case failed(String)
    }

    struct Choice: Identifiable {
        let provider: Provider
        var id: String { provider.id }
        var detected = false
        var connection = Connection.notChecked
    }

    static let accessDeniedMessage = "Access wasn't granted. You can retry or skip for now."

    private let cards: [ProviderRuntime]
    private let enablement: ProviderEnablementStore
    private let dataStore: WidgetDataStore
    private(set) var choices: [Choice]
    var selectedIDs: Set<String> = []
    var showAll = false
    private(set) var isDetecting = true
    private(set) var isConnecting = false
    private(set) var hasAttemptedConnection = false
    var visibleChoices: [Choice] { choices.filter { showAll || $0.detected } }
    var hasFailures: Bool {
        choices.contains { if case .failed = $0.connection { true } else { false } }
    }

    /// `providers` are the choices, one per provider. `cards` are the dashboard's cards, built from
    /// every sign-in found at launch, where one provider can have a card per account.
    init(
        providers: [Provider],
        cards: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        dataStore: WidgetDataStore
    ) {
        self.cards = cards
        self.enablement = enablement
        self.dataStore = dataStore
        self.choices = providers.map { Choice(provider: $0) }
    }

    func detect() async {
        let detectedCards = await FirstRunSeeder.detectLocalProviders(cards)
        let detected = Set(detectedCards.map(ProviderAccountID.family(of:)))
        guard !Task.isCancelled else { return }
        for index in choices.indices where detected.contains(choices[index].id) {
            choices[index].detected = true
        }
        selectedIDs = detected
        isDetecting = false
        AppLog.info(.config, "welcome: detected \(detected.sorted())")
    }

    /// Connecting is the user asking, so popups are allowed from here on and a login they denied may
    /// ask again. A provider that already connected isn't fetched again on retry.
    func connectSelected() async {
        guard !isConnecting, !isDetecting else { return }
        isConnecting = true
        hasAttemptedConnection = true
        defer { isConnecting = false }
        KeychainAccessGuard.allowPopups()
        KeychainAccessGuard.forgetDenials()
        for index in choices.indices {
            let id = choices[index].id
            guard selectedIDs.contains(id), choices[index].connection != .connected else { continue }
            guard !Task.isCancelled else { return }
            choices[index].connection = .checking
            choices[index].connection = await connect(id)
            AppLog.info(.config, "welcome: \(id) → \(choices[index].connection)")
        }
    }

    /// Turns on each of the provider's cards and refreshes it once no earlier popup is still open. A
    /// card that fails goes back off, and the first failure is what the row shows.
    private func connect(_ providerID: String) async -> Connection {
        let deniedBefore = KeychainAccessGuard.denials()
        var failure: String?
        for cardID in cards.map(\.provider.id) where ProviderAccountID.family(of: cardID) == providerID {
            await KeychainAccessGuard.waitForReadsToFinish()
            enablement.setEnabled(true, for: cardID)
            await dataStore.refresh(providerID: cardID, force: true)
            guard let message = dataStore.errorMessage(for: cardID) else { continue }
            enablement.setEnabled(false, for: cardID)
            failure = failure ?? message
        }
        guard let failure else { return .connected }
        return .failed(KeychainAccessGuard.denials() == deniedBefore ? failure : Self.accessDeniedMessage)
    }
}
