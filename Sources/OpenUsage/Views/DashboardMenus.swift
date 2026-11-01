import SwiftUI

enum DashboardCommand: Equatable {
    case refresh([String])
    case manageAccounts
    case open(URL)
    case rename(String)
    case editAccount(String)
    case shareScreenshot([String])
}

struct DashboardMenuItem: Equatable {
    let title: String
    var command: DashboardCommand?
}

enum DashboardMenus {
    typealias Sections = [[DashboardMenuItem]]

    static func provider(_ family: DashboardFamily) -> Sections {
        [
            [DashboardMenuItem(title: "Refresh", command: .refresh(family.accounts.map(\.id)))],
            [DashboardMenuItem(title: "Manage Accounts…", command: .manageAccounts)],
            [DashboardMenuItem(title: "Share Screenshot", command: .shareScreenshot(family.accounts.map(\.id)))],
            links(family.provider),
        ].filter { !$0.isEmpty }
    }

    private static func links(_ provider: Provider) -> [DashboardMenuItem] {
        provider.links.map { DashboardMenuItem(title: $0.label, command: .open($0.url)) }
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
                Button(entry.title) {
                    if let command = entry.command { perform(command) }
                }
                .disabled(entry.command == nil)
            }
        }
    }
}
