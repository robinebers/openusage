import SwiftUI

/// What a dashboard right-click menu item does. `WidgetGroupedListView` performs it.
enum DashboardCommand: Equatable {
    case refresh([String])
    case manageAccounts
    case open(URL)
    case rename(String)
    case editAccount(String)
    /// Copies a picture of these accounts' card: a provider's accounts, or one of them.
    case shareScreenshot([String])
    case showHiddenMetrics(String)
    case toggleStar(String)
    case hide(String)
}

struct DashboardMenuItem: Equatable {
    let title: String
    /// `nil` shows the title as a disabled line.
    var command: DashboardCommand?
}

/// The dashboard's right-click menus, one per thing you can click: a provider's header or card, an
/// account's caption, and a metric row. Each is a list of sections that render with dividers between them. Apart from the
/// Limit Resets row's popover, right-click is the only way to act on the dashboard, and Share Screenshot
/// here the only way to copy a picture of it.
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

    /// `status` explains the account line's warning or stale icon.
    static func account(
        _ account: DashboardAccount,
        status: String?,
        hasHiddenMetrics: Bool
    ) -> Sections {
        [
            status.map { [DashboardMenuItem(title: $0)] } ?? [],
            [
                DashboardMenuItem(title: "Refresh", command: .refresh([account.id])),
                DashboardMenuItem(title: "Rename", command: .rename(account.id)),
                DashboardMenuItem(title: "Edit Account…", command: .editAccount(account.id)),
            ],
            [DashboardMenuItem(title: "Share Screenshot", command: .shareScreenshot([account.id]))],
            hasHiddenMetrics ? [DashboardMenuItem(title: "Show Hidden Metrics", command: .showHiddenMetrics(account.id))] : [],
        ].filter { !$0.isEmpty }
    }

    static func metric(_ descriptor: WidgetDescriptor, isStarred: Bool) -> Sections {
        [[
            DashboardMenuItem(title: isStarred ? "Unstar" : "Star for Menu Bar", command: .toggleStar(descriptor.id)),
            DashboardMenuItem(title: "Hide", command: .hide(descriptor.id)),
        ]]
    }
}

/// Renders a `DashboardMenus` list inside `.contextMenu`.
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
