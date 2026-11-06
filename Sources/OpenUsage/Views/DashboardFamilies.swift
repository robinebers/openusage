import Foundation

struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    var accounts: [DashboardAccount]

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

    var id: String { provider.id }
    var name: String { provider.accountName }
    var hidingEmail: DashboardAccount {
        DashboardAccount(provider: provider.hidingEmail, lines: lines, waitingMetricIDs: waitingMetricIDs)
    }
}

struct DashboardLine: Identifiable {
    let descriptor: WidgetDescriptor
    let data: WidgetData
    var id: String { descriptor.id }

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
        for group in groups {
            let account = isWaiting(group.provider)
                ? DashboardAccount(provider: group.provider, lines: [], waitingMetricIDs: group.metrics.map(\.id))
                : DashboardAccount(provider: group.provider, lines: group.metrics.map(line).filter(\.isVisible))
            let familyID = group.provider.kind.rawValue
            if let index = families.firstIndex(where: { $0.id == familyID }) {
                families[index].accounts.append(account)
            } else {
                families.append(DashboardFamily(id: familyID, provider: group.provider, accounts: [account]))
            }
        }
        return families
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
