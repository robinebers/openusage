import Foundation

struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    var accounts: [DashboardAccount]

    /// The family's account when it has just the one, which then has no caption of its own.

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

    var id: String { provider.id }
    var name: String { provider.accountName }
    var hidingEmail: DashboardAccount { DashboardAccount(provider: provider.hidingEmail, lines: lines) }
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
    static func make(groups: [ProviderMetrics], line: (WidgetDescriptor) -> DashboardLine) -> [DashboardFamily] {
        var families: [DashboardFamily] = []
        for group in groups {
            let lines = group.metrics.map(line).filter(\.isVisible)
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
        var copy = self; copy.accountLabel = nil; return copy
    }
}
