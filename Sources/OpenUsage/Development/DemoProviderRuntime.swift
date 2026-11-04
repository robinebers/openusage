#if OPENUSAGE_DEVELOPMENT
import Foundation

/// The real dashboard reads these local snapshots through its existing runtime protocol.
@MainActor
final class DemoProviderRuntime: ProviderRuntime {
    var account: Account
    private let now: () -> Date

    var provider: Provider { AccountProviderRuntime.provider(for: account) }
    var widgetDescriptors: [WidgetDescriptor] { AccountProviderRuntime.widgetDescriptors(for: account) }

    init(account: Account, now: @escaping () -> Date = Date.init) {
        self.account = account
        self.now = now
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        .success(DemoFixtures.snapshot(for: account, at: now()))
    }

    static func make(accounts: [Account], existing: [ProviderRuntime]) -> [ProviderRuntime] {
        let saved = Dictionary(
            existing.compactMap { runtime -> (UUID, DemoProviderRuntime)? in
                guard let runtime = runtime as? DemoProviderRuntime else { return nil }
                return (runtime.account.id, runtime)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return accounts.map { account in
            guard let runtime = saved[account.id] else { return DemoProviderRuntime(account: account) }
            runtime.account = account
            return runtime
        }
    }
}
#endif
