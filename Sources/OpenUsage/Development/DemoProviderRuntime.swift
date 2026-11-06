#if OPENUSAGE_DEVELOPMENT
import Foundation

/// The real dashboard reads the demo's sample readings through its existing runtime protocol.
@MainActor
final class DemoProviderRuntime: ProviderRuntime {
    var account: Account
    private let read: @MainActor (Account) -> ProviderSnapshot

    var provider: Provider { AccountProviderRuntime.provider(for: account) }
    var widgetDescriptors: [WidgetDescriptor] { AccountProviderRuntime.widgetDescriptors(for: account) }

    init(account: Account, read: @escaping @MainActor (Account) -> ProviderSnapshot) {
        self.account = account
        self.read = read
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        var snapshot = read(account)
        snapshot.refreshedAt = Date()
        return .success(snapshot)
    }

    static func make(
        accounts: [Account], existing: [ProviderRuntime], read: @escaping @MainActor (Account) -> ProviderSnapshot
    ) -> [ProviderRuntime] {
        let saved = Dictionary(
            existing.compactMap { runtime -> (UUID, DemoProviderRuntime)? in
                guard let runtime = runtime as? DemoProviderRuntime else { return nil }
                return (runtime.account.id, runtime)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return accounts.map { account in
            guard let runtime = saved[account.id] else { return DemoProviderRuntime(account: account, read: read) }
            runtime.account = account
            return runtime
        }
    }
}
#endif
