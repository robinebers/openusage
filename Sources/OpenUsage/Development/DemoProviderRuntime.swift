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

    /// Sample Claude resets read as Fable resets, so their heading and confirmation show without an
    /// account. Spending one sends nothing.
    func resetClaimService(
        refreshAccount: @escaping @MainActor () async -> WidgetDataStore.RefreshOutcome
    ) -> ResetClaimService? {
        guard account.kind == .claude else { return nil }
        let grant = ClaudeResetGrantStatus.Grant(
            id: "sample-fable", resetsLeft: 1, endsAt: nil,
            clears: ["five_hour", "seven_day_overage_included"], givesBackWeekly: true
        )
        let status = ClaudeResetGrantStatus(eligible: true, grants: [grant], nextGrantID: grant.id)
        return ResetClaimService(
            accountID: account.cardID,
            isClaimable: true,
            confirmDetail: status.confirmDetail,
            claimReset: { _, _ in .success },
            refreshAccount: refreshAccount,
            scopeTitle: status.scopeTitle(now: Date())
        )
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
