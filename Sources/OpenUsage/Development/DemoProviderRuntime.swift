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

    /// Sample ChatGPT resets are ordinary ones. A sample Claude account's resets go by their count, so
    /// every layout and confirmation shows without an account: one is ordinary, two are Fable ones,
    /// three are a Fable one and two ordinary. Spending one sends nothing.
    func resetClaimService(
        expiries: [Date], refreshAccount: @escaping @MainActor () async -> WidgetDataStore.RefreshOutcome
    ) -> ResetClaimService? {
        if account.kind == .codex {
            return ResetClaimService(
                accountID: account.cardID, isClaimable: true, confirmDetail: nil,
                claimReset: { _, _ in .success }, refreshAccount: refreshAccount,
                timelineTitle: ResetClaimService.sessionAndWeeklyTitle
            )
        }
        guard account.kind == .claude else { return nil }
        let grants = expiries.sorted().enumerated().map { index, expiry in
            let isFable = expiries.count == 2 || (expiries.count > 2 && index == 0)
            return ClaudeResetGrantStatus.Grant(
                id: isFable ? "sample-fable-\(index)" : "sample-\(index)", resetsLeft: 1, endsAt: expiry,
                clears: ["five_hour", isFable ? "seven_day_overage_included" : "seven_day"], givesBackWeekly: isFable
            )
        }
        let status = ClaudeResetGrantStatus(eligible: true, grants: grants, nextGrantID: grants.first?.id)
        return ResetClaimService(
            accountID: account.cardID,
            isClaimable: status.claimableGrantID != nil,
            confirmDetail: status.confirmDetail,
            claimReset: { _, _ in .success },
            refreshAccount: refreshAccount,
            sections: status.sections(now: Date())
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
