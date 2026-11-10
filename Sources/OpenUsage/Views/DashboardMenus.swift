import SwiftUI

enum DashboardCommand: Equatable {
    case refresh([String])
    case manageAccounts
    case open(URL)
    case rename(String)
    case editAccount(String)
    case shareScreenshot([String])
    /// Each metric in one step, such as every account's copy of a unified limit.
    case setPinned([String], Bool)
    case hide([String])
    case unifyAccounts(ProviderKind, Bool)
}

struct DashboardMenuItem: Equatable {
    let title: String
    var command: DashboardCommand?
    var systemImage: String?
    /// A setting's item, with a checkmark while it's on.
    var isChecked: Bool?
}

enum DashboardMenus {
    typealias Sections = [[DashboardMenuItem]]

    static func provider(_ family: DashboardFamily) -> Sections {
        let unify = family.accountIDs.count > 1 && ProviderKind.unifiable.contains(family.provider.kind) ? [DashboardMenuItem(
            title: "Unify Multiple Accounts", command: .unifyAccounts(family.provider.kind, !family.isUnified), isChecked: family.isUnified
        )] : []
        return [
            [DashboardMenuItem(title: "Refresh", command: .refresh(family.accountIDs))],
            [DashboardMenuItem(title: "Manage Accounts…", command: .manageAccounts)] + unify,
            [DashboardMenuItem(title: "Share Screenshot", command: .shareScreenshot(family.accounts.map(\.id)))],
            links(family.provider),
        ].filter { !$0.isEmpty }
    }

    private static func links(_ provider: Provider) -> [DashboardMenuItem] {
        provider.links.map { DashboardMenuItem(title: $0.label, command: .open($0.url)) }
    }

    static func metric(_ metricIDs: [String], pinned: Bool) -> [DashboardMenuItem] {
        [
            pinned
                ? DashboardMenuItem(title: "Unpin", command: .setPinned(metricIDs, false), systemImage: "pin.slash")
                : DashboardMenuItem(title: "Pin", command: .setPinned(metricIDs, true), systemImage: "pin"),
            DashboardMenuItem(title: "Hide", command: .hide(metricIDs), systemImage: "eye.slash"),
        ]
    }

    static func account(_ account: DashboardAccount, status: String?) -> Sections {
        [
            status.map { [DashboardMenuItem(title: $0)] } ?? [],
            [
                DashboardMenuItem(title: "Refresh", command: .refresh([account.id])),
                DashboardMenuItem(title: "Rename", command: .rename(account.id)),
                DashboardMenuItem(title: "Edit Account…", command: .editAccount(account.id)),
            ],
            [DashboardMenuItem(title: "Share Screenshot", command: .shareScreenshot([account.id]))],
            account.provider.organizationBillingPage.map { [DashboardMenuItem(title: "Organization Billing", command: .open($0))] } ?? [],
        ].filter { !$0.isEmpty }
    }
}

struct DashboardMenu: View {
    let sections: DashboardMenus.Sections
    let perform: (DashboardCommand) -> Void

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index].indices, id: \.self) { item in
                let entry = sections[index][item]
                if let isChecked = entry.isChecked {
                    Toggle(entry.title, isOn: Binding(
                        get: { isChecked },
                        set: { _ in if let command = entry.command { perform(command) } }
                    ))
                } else {
                    Button {
                        if let command = entry.command { perform(command) }
                    } label: {
                        if let systemImage = entry.systemImage {
                            Label(entry.title, systemImage: systemImage)
                        } else {
                            Text(entry.title)
                        }
                    }
                    .disabled(entry.command == nil)
                }
            }
        }
    }
}
