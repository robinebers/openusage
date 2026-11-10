import Foundation

struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    var accounts: [DashboardAccount]

    /// Unify Multiple Accounts is on: the card shows one account standing for all of them.
    var isUnified: Bool { accounts.contains { !$0.members.isEmpty } }
    /// The accounts the card stands for, unified or not, in the user's order.
    var accountIDs: [String] { accounts.flatMap(\.accountIDs) }

    var hidingEmails: DashboardFamily {
        DashboardFamily(
            id: id, provider: provider.hidingEmail,
            accounts: accounts.map(\.hidingEmail)
        )
    }
}

struct DashboardAccount: Identifiable {
    let provider: Provider
    let lines: [DashboardLine]
    /// Before the account's first reading, the metrics it shows, each drawn as a skeleton row.
    var waitingMetricIDs: [String] = []
    /// For a unified account, the accounts it stands for, in the user's order.
    var members: [DashboardAccount] = []

    var id: String { provider.id }
    var name: String { provider.accountName }
    var accountIDs: [String] { members.isEmpty ? [id] : members.map(\.id) }
    var hidingEmail: DashboardAccount {
        DashboardAccount(provider: provider.hidingEmail, lines: lines, waitingMetricIDs: waitingMetricIDs, members: members.map(\.hidingEmail))
    }
}

struct DashboardLine: Identifiable {
    /// One account's own reading of a unified limit.
    struct Member: Identifiable {
        let provider: Provider
        let line: DashboardLine
        var id: String { line.id }
    }

    let descriptor: WidgetDescriptor
    let data: WidgetData
    /// For a unified limit, every account that reports it, in the user's order.
    var members: [Member] = []
    /// For a unified limit, every account's copy of it, including accounts still waiting for a reading.
    var copyIDs: [String] = []
    var id: String { descriptor.id }

    /// What Pin and Hide act on: each account's own copy of a unified limit.
    var metricIDs: [String] { copyIDs.isEmpty ? [id] : copyIDs }

    // Spent reset grants remain available to CLI clients.
    var isVisible: Bool {
        guard data.hasData else { return false }
        if data.showsResetExpiries { return data.resetCreditCount > 0 }
        return true
    }
}

extension DashboardFamily {
    static func make(
        groups: [ProviderMetrics], isWaiting: (Provider) -> Bool = { _ in false }, line: (WidgetDescriptor) -> DashboardLine
    ) -> [DashboardFamily] {
        var families: [DashboardFamily] = []
        var unifying: Set<String> = []
        for group in groups {
            let account = isWaiting(group.provider)
                ? DashboardAccount(provider: group.provider, lines: [], waitingMetricIDs: group.metrics.map(\.id))
                : DashboardAccount(provider: group.provider, lines: group.metrics.map(line).filter(\.isVisible))
            let familyID = group.provider.kind.rawValue
            if group.unifiesAccounts { unifying.insert(familyID) }
            if let index = families.firstIndex(where: { $0.id == familyID }) {
                families[index].accounts.append(account)
            } else {
                families.append(DashboardFamily(id: familyID, provider: group.provider, accounts: [account]))
            }
        }
        return families.map { unifying.contains($0.id) ? $0.unifyingAccounts() : $0 }
    }
}

extension Provider {
    var isNamedByEmail: Bool {
        accountLabel?.contains("@") ?? false
    }

    var hidingEmail: Provider {
        guard isNamedByEmail else { return self }
        var copy = self; copy.accountLabel = nil; return copy
    }
}
