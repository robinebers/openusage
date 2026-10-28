import Foundation

struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    var accounts: [DashboardAccount]

    var hidingEmails: DashboardFamily {
        DashboardFamily(
            id: id, provider: provider.hidingEmail,
            accounts: accounts.map { DashboardAccount(provider: $0.provider.hidingEmail, lines: $0.lines) }
        )
    }
}

struct DashboardAccount: Identifiable {
    let provider: Provider
    let lines: [DashboardLine]

    var id: String { provider.id }
    var name: String { provider.accountName }
}

struct DashboardLine: Identifiable {
    let descriptor: WidgetDescriptor
    let data: WidgetData
    var id: String { descriptor.id }
}

extension DashboardFamily {
    static func make(groups: [ProviderMetrics], line: (WidgetDescriptor) -> DashboardLine) -> [DashboardFamily] {
        var families: [DashboardFamily] = []
        for group in groups {
            let lines = group.metrics.map(line).filter {
                $0.data.hasData && (!$0.data.showsResetExpiries || $0.data.resetCreditCount > 0)
            }
            let account = DashboardAccount(provider: group.provider, lines: lines)
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
        return Provider(id: id, kind: kind)
    }
}
