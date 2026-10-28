import AppKit
import SwiftUI

/// The dashboard display: one provider after another (`DashboardFamily`), each a header above a card
/// of its accounts, every account one row per metric that has data, fed by the same `WidgetDataStore`
/// the menu bar uses. Every row shows its label, bar, value and reset at rest and draws the same under
/// the pointer; resting it on the bar, the value or the reset opens a tooltip with the figure the row
/// doesn't show, and on the Limit Resets row's count the resets timeline after a dwell. A click on a
/// value flips every row between used and left, a click on a reset between countdown and exact time.
/// A double-click on an account's name on its caption renames it, the same as the menu's Rename.
///
/// Right-click a provider's header or card, an account's caption, or a metric row for its menu
/// (`DashboardMenus`). Share Screenshot there copies a picture: the provider's with all its accounts, or
/// one account's; the copy button a provider's header reveals on hover copies the same picture of the
/// provider. Everything reorders by dragging: a provider by its header, an account by its caption
/// within its card, a metric row within its account.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(AccountRenameStore.self) private var renaming
    @Environment(PopoverState.self) private var popover
    @Environment(\.colorScheme) private var colorScheme
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var frameStore = ReorderFrameStore()
    @State private var activeMetricID: String?
    @State private var activeAccountID: String?
    @State private var activeFamilyID: String?

    var body: some View {
        let families = liveFamilies()
        VStack(alignment: .leading, spacing: DashboardGrid.sectionSpacing) {
            ForEach(families) { family in
                section(family)
                    .contextMenu { DashboardMenu(sections: DashboardMenus.provider(family), perform: perform) }
                    .opacity(activeFamilyID == Self.familyFrameID(family.id) ? 0 : 1)
                    .reorderFrame(id: Self.familyFrameID(family.id), in: .named(reorderSpaceName))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frameStore.frames = $0 }
        .animation(Motion.spring, value: families.map(\.id))
    }

    private func resolveLine(_ descriptor: WidgetDescriptor) -> DashboardLine {
        DashboardLine(descriptor: descriptor, data: dataStore.data(for: descriptor))
    }

    private func liveFamilies() -> [DashboardFamily] {
        DashboardFamily.make(groups: layout.displayGroups, line: resolveLine)
    }

    private func plans(for family: DashboardFamily) -> [String: String] {
        Dictionary(uniqueKeysWithValues: family.accounts.compactMap { account in
            dataStore.plan(for: account.id).map { (account.id, $0) }
        })
    }

    private func status(for accountID: String) -> AccountStatus {
        AccountStatus(
            refreshing: dataStore.refreshingProviderIDs.contains(accountID),
            notice: dataStore.errorMessage(for: accountID),
            staleness: dataStore.stalenessHint(for: accountID)
        )
    }

    // MARK: - Sections

    /// A provider with its drag and copy button on the header; the whole section takes its right-click menu.
    private func section(_ family: DashboardFamily) -> some View {
        DashboardProviderSection(family: family) {
            DashboardProviderHeader(provider: family.provider, onCopyScreenshot: { shareScreenshot(family.accounts.map(\.id)) })
                .highPriorityGesture(familyDragGesture(for: family))
        } account: { account in
            accountSection(account, in: family)
        }
        .contentShape(Rectangle())
    }

    /// An account: its caption over its rows, with the account's menu and the caption's drag.
    private func accountSection(_ account: DashboardAccount, in family: DashboardFamily) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(account: account, plan: dataStore.plan(for: account.id), status: status(for: account.id))
                .highPriorityGesture(accountDragGesture(for: account, in: family))
            rows(of: account)
        }
        .contextMenu {
            DashboardMenu(
                sections: DashboardMenus.account(
                    account,
                    status: statusReason(for: account.id),
                    hasHiddenMetrics: !hiddenMetricIDs(for: account.id).isEmpty
                ),
                perform: perform
            )
        }
        .opacity(activeAccountID == account.id ? 0 : 1)
        .reorderFrame(id: account.id, in: .named(reorderSpaceName))
    }

    /// The account's rows, one under the other with nothing between, each with its right-click menu
    /// and drag. One view, so the card's account spacing never lands between two rows.
    private func rows(of account: DashboardAccount) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(account.lines) { line in
                DashboardLiveRow(
                    line: line,
                    resetClaim: container.resetClaim(for: account.id),
                    onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                    onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() }
                )
                    .opacity(activeMetricID == line.id ? 0 : 1)
                    .highPriorityGesture(metricDragGesture(for: line, accountID: account.id))
                    .contextMenu {
                        DashboardMenu(
                            sections: DashboardMenus.metric(line.descriptor, isStarred: layout.isPinned(line.descriptor.id)),
                            perform: perform
                        )
                    }
                    .reorderFrame(id: line.id, in: .named(reorderSpaceName))
            }
        }
    }

    /// Why the account shows a warning or stale icon.
    private func statusReason(for accountID: String) -> String? {
        dataStore.errorMessage(for: accountID) ?? dataStore.stalenessHint(for: accountID)
    }

    /// Metrics the user hid from this account that have something to show.
    private func hiddenMetricIDs(for accountID: String) -> [String] {
        layout.orderedSupportedMetrics(for: accountID)
            .filter { !layout.isMetricEnabled($0.id) && dataStore.data(for: $0).hasData }
            .map(\.id)
    }

    // MARK: - Menu commands

    private func perform(_ command: DashboardCommand) {
        switch command {
        case .refresh(let accountIDs):
            Task { await dataStore.refresh(providerIDs: accountIDs, force: true) }
        case .manageAccounts:
            openAccounts(nil)
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .rename(let accountID):
            renaming.begin(accountID)
        case .editAccount(let accountID):
            openAccounts(accountID)
        case .shareScreenshot(let accountIDs):
            shareScreenshot(accountIDs)
        case .showHiddenMetrics(let accountID):
            layout.showMetrics(hiddenMetricIDs(for: accountID))
        case .toggleStar(let descriptorID):
            if layout.isPinned(descriptorID) || layout.canPin(descriptorID) {
                layout.togglePin(descriptorID)
            } else if let reason = layout.pinDenialReason(descriptorID) {
                popover.pinNotice.present(reason)
            }
        case .hide(let descriptorID):
            layout.setMetricEnabled(descriptorID, false)
        }
    }

    /// Copies a picture of these accounts' card to the clipboard: the menu's Share Screenshot and the
    /// header's copy button, through one path.
    @discardableResult
    private func shareScreenshot(_ accountIDs: [String]) -> Bool {
        guard let live = liveFamilies().first(where: { $0.accounts.contains { accountIDs.contains($0.id) } }) else { return false }
        let accounts = live.accounts.filter { accountIDs.contains($0.id) }
        let family = DashboardFamily(id: live.id, provider: accounts[0].provider, accounts: accounts)
        guard ShareCardRenderer.share(family: family, plans: plans(for: family), appearance: colorScheme) else { return false }
        popover.shareNotice.present(true)
        return true
    }

    /// Opens the Accounts screen, on one account's page when `providerID` is set.
    private func openAccounts(_ providerID: String?) {
        withAnimation(Motion.modeSwitch) {
            popover.customizeProviderID = providerID
            popover.screen = .accounts
        }
    }

    // MARK: - Reordering

    /// The account's visible line ids, read live so a drag sees each reorder it has already made.
    private func visibleLineIDs(for accountID: String) -> [String] {
        liveFamilies().flatMap(\.accounts).first { $0.id == accountID }?.lines.map(\.id) ?? []
    }

    private func metricDragGesture(for line: DashboardLine, accountID: String) -> some Gesture {
        reorderDragGesture(
            id: line.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = DashboardMetricRow(model: line.data.dashboardRow())
                    .padding(.horizontal, DashboardGrid.cardPadding)
                    .liftedRowSurface()
                return ReorderLift.make(id: line.id, preview: AnyView(preview), value: value, frames: frameStore.frames)
            },
            orderedIDs: { visibleLineIDs(for: accountID) },
            reorder: { layout.reorderMetric(dragged: line.id, target: $0, in: accountID) }
        )
    }

    private static func familyFrameID(_ familyID: String) -> String { "family:\(familyID)" }

    private func accountDragGesture(for account: DashboardAccount, in family: DashboardFamily) -> some Gesture {
        reorderDragGesture(
            id: account.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeAccountID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = DashboardAccountRows(account: account, plan: dataStore.plan(for: account.id))
                    .padding(DashboardGrid.cardPadding)
                    .liftedRowSurface()
                return ReorderLift.make(id: account.id, preview: AnyView(preview), value: value, frames: frameStore.frames)
            },
            orderedIDs: { liveFamilies().first { $0.id == family.id }?.accounts.map(\.id) ?? [] },
            reorder: { layout.reorderProvider(dragged: account.id, target: $0) }
        )
    }

    private func familyDragGesture(for family: DashboardFamily) -> some Gesture {
        let frameID = Self.familyFrameID(family.id)
        return reorderDragGesture(
            id: frameID,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeFamilyID,
            lift: $reorderLift,
            makeLift: { value in
                let plans = plans(for: family)
                let preview = DashboardProviderSection(family: family) { account in
                    DashboardAccountRows(account: account, plan: plans[account.id])
                }
                return ReorderLift.make(id: frameID, preview: AnyView(preview), value: value, frames: frameStore.frames)
            },
            orderedIDs: { liveFamilies().map { Self.familyFrameID($0.id) } },
            reorder: { target in
                layout.reorderFamily(dragged: family.id, target: String(target.dropFirst("family:".count)))
            }
        )
    }
}
