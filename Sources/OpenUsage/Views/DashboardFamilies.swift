import Foundation

/// The dashboard's shape: one card per provider (Claude, Codex, …) holding that provider's accounts in
/// the user's account order. Built from `LayoutStore.displayGroups`, which has one group per account.
/// Every enabled reading that carries data becomes a line; the Limit Resets reading only while a reset
/// is available.
struct DashboardFamily: Identifiable {
    let id: String
    /// The first account's provider, which supplies the card's mark and name.
    let provider: Provider
    var accounts: [DashboardAccount]

    /// The same family with every email address left out of its account names, for an image that
    /// leaves the panel: an account named by its email reads as its provider alone.
    var hidingEmails: DashboardFamily {
        DashboardFamily(
            id: id, provider: provider.hidingEmail,
            accounts: accounts.map { DashboardAccount(provider: $0.provider.hidingEmail, lines: $0.lines) }
        )
    }
}

struct DashboardAccount: Identifiable {
    let provider: Provider
    /// One line per enabled metric that has data, in the user's order.
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
    /// Groups accounts under their provider in order of first appearance. Every enabled metric that
    /// has data is a line; nothing is tucked behind a click.
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
    /// Whether the account is named by an email address rather than a name of its own.
    var isNamedByEmail: Bool {
        accountLabel?.contains("@") ?? false
    }

    /// The provider with an email account name left out.
    var hidingEmail: Provider {
        guard isNamedByEmail else { return self }
        return Provider(id: id, kind: kind)
    }
}
