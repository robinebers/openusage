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

    /// Sample resets show every kind without an account, and spending one sends nothing. ChatGPT's are
    /// Full Resets. Z.ai's alternate Session and Weekly. A sample Claude account's go by their count, set
    /// from the same fields Anthropic sends: one is a Weekly Reset, two are Fable Resets, and three are a
    /// Weekly Reset then two Fable Resets, like a Max login holding the Fable launch grants.
    func resetClaimService(
        expiries: [Date], refreshAccount: @escaping @MainActor () async -> WidgetDataStore.RefreshOutcome
    ) -> ResetClaimService? {
        let sorted = expiries.sorted()
        let items: [ResetItem]
        switch account.kind {
        case .codex:
            items = sorted.map { ResetItem(kind: .full, expiresAt: $0, claim: .codexCredit($0)) }
        case .zai:
            items = ZAIResetsMapper.items(sorted.enumerated().map { index, expiry in
                ZAIReset(window: index.isMultiple(of: 2) ? .fiveHour : .week, recordID: index, expiresAt: expiry, grantType: "SAMPLE")
            })
        case .claude:
            let grants = sorted.enumerated().map { index, expiry in
                let isFable = sorted.count == 2 || (sorted.count > 2 && index > 0)
                return ClaudeResetGrantStatus.Grant(
                    id: "sample-\(index)", resetsLeft: 1, endsAt: expiry,
                    clears: isFable ? ["seven_day_overage_included"] : ["seven_day", "seven_day_overage_included"],
                    type: isFable ? "full" : "weekly", givesBackWeekly: isFable, usableNow: true
                )
            }
            items = ClaudeResetGrantStatus(eligible: true, grants: grants, nextGrantID: grants.first?.id).items(now: Date())
        default:
            return nil
        }
        return ResetClaimService(
            accountID: account.cardID, items: items, claimReset: { _, _ in .success }, refreshAccount: refreshAccount
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
