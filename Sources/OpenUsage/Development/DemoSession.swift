#if OPENUSAGE_DEVELOPMENT
import Foundation
import Observation

/// One run of the isolated demo app: its seed and the sample readings its accounts show.
@MainActor
@Observable
final class DemoSession {
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

    /// Clears only the demo app's own defaults domain, so it can never reset a normal app's accounts or settings.
    static func makeContainer(defaults: UserDefaults, seed: Int? = nil, now: Date = Date()) -> AppContainer {
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
        AppLog.info(.lifecycle, "demo seed \(session.seed)")
        return container
    }

    func reshuffle() {
        shuffle(seed: .random(in: Self.seeds), now: Date())
        AppLog.info(.lifecycle, "demo seed \(seed)")
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
}
#endif
