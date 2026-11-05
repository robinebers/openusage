#if OPENUSAGE_DEVELOPMENT
import Foundation
import Observation

/// One run of the isolated demo app: its seed and the sample readings its accounts show.
@MainActor
@Observable
final class DemoSession {
    static let marker = "OPENUSAGE_DEVELOPMENT_DEMO_FIXTURE_V1"
    /// Pins the seed from the launch arguments, as in `-DemoSeed 4242`.
    static let seedKey = "DemoSeed"
    static let seeds = 1...999_999

    private(set) var seed = 0
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private var snapshots: [UUID: ProviderSnapshot] = [:]
    @ObservationIgnored private var random = DemoRandom(seed: 0)

    private init(accounts: AccountStore) {
        self.accounts = accounts
    }

    static func requested(bundleIdentifier: String?, arguments: [String]) throws -> Bool {
        let wantsDemo = arguments.contains(DevelopmentDataMode.demoArgument)
        guard bundleIdentifier == DevelopmentDataMode.demoBundleID else {
            guard !wantsDemo else { throw unavailable("Sample Data requires the isolated development demo app.") }
            return false
        }
        guard wantsDemo else { throw unavailable("Open Sample Data from the development app’s settings.") }
        return true
    }

    /// Clears only the demo app's own defaults domain, so it can never reset a normal app's accounts or settings.
    static func makeContainer(defaults: UserDefaults, seed: Int? = nil, now: Date = Date()) throws -> AppContainer {
        defaults.removePersistentDomain(forName: DevelopmentDataMode.demoBundleID)
        let pinned = defaults.object(forKey: seedKey) == nil ? nil : defaults.integer(forKey: seedKey)
        let store = AccountStore(defaults: defaults, vault: DemoCredentialVault(), hubKeys: DemoHubKeyVault())
        let session = DemoSession(accounts: store)
        let container = AppContainer(
            accounts: store, defaults: defaults, http: DemoHTTPClient(),
            telemetry: DemoTelemetrySink(), telemetryDefaults: defaults,
            runtimeFactory: { DemoProviderRuntime.make(accounts: $0, existing: $1, read: session.snapshot(for:)) }
        )
        container.demo = session
        session.shuffle(seed: seed ?? pinned ?? .random(in: seeds), now: now)
        AppLog.info(.lifecycle, "\(marker) seed \(session.seed)")
        return container
    }

    func reshuffle() {
        shuffle(seed: .random(in: Self.seeds), now: Date())
        AppLog.info(.lifecycle, "\(Self.marker) seed \(seed)")
    }

    func snapshot(for account: Account) -> ProviderSnapshot {
        if let snapshot = snapshots[account.id] { return snapshot }
        let added = DemoFactory.snapshots(for: [account], now: Date(), using: &random)[account.id]!
        snapshots[account.id] = added
        return added
    }

    /// Replaces every account in place, so the dashboard swaps runtimes as it does for any account change.
    private func shuffle(seed: Int, now: Date) {
        self.seed = seed
        random = DemoRandom(seed: seed)
        for account in accounts.accounts { accounts.remove(account.id) }
        for entry in DemoFactory.accounts(using: &random) {
            accounts.add(kind: entry.kind, label: entry.label, organization: entry.organization, credential: .apiKey("sample"))
        }
        snapshots = DemoFactory.snapshots(for: accounts.accounts, now: now, using: &random)
    }

    private static func unavailable(_ message: String) -> ProviderError {
        AppLog.error(.lifecycle, message)
        return .unavailable(message)
    }
}
#endif
