import AppKit
import SwiftUI

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

    private func liveFamilies() -> [DashboardFamily] {
        dataStore.families(in: layout.displayGroups)
    }

    private func plans(for family: DashboardFamily) -> [String: String] {
        Dictionary(uniqueKeysWithValues: family.accounts.compactMap { account in
            dataStore.plan(for: account.id).map { (account.id, $0) }
        })
    }

    private func status(for accountID: String) -> AccountStatus {
        AccountStatus(
            refreshing: dataStore.refreshingProviderIDs.contains(accountID),
            notice: dataStore.notice(for: accountID),
            staleness: dataStore.stalenessHint(for: accountID),
            onFix: { popover.openAccounts(accountID) }
        )
    }

    private func section(_ family: DashboardFamily) -> some View {
        DashboardProviderSection(family: family) { isHovered in
            DashboardProviderHeader(family: family, isRevealed: isHovered, onCopyScreenshot: { shareScreenshot(family.accounts.map(\.id)) })
            .highPriorityGesture(familyDragGesture(for: family))
        } account: { account in
            accountSection(account, in: family)
        }
    }

    private func accountSection(_ account: DashboardAccount, in family: DashboardFamily) -> some View {
        let accountStatus = status(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(account: account, plan: dataStore.plan(for: account.id),
                                    status: accountStatus, hasSiblingAccounts: family.accounts.count > 1)
                .highPriorityGesture(accountDragGesture(for: account, in: family))
            rows(of: account, status: accountStatus)
        }
        .contextMenu {
            DashboardMenu(
                sections: DashboardMenus.account(account, status: accountStatus.notice ?? accountStatus.staleness),
                perform: perform
            )
        }
        .id(account.id)
        .opacity(activeAccountID == account.id ? 0 : 1)
        .reorderFrame(id: account.id, in: .named(reorderSpaceName))
    }

    private func rows(of account: DashboardAccount, status: AccountStatus) -> some View {
        DashboardLineStack(account: account) { line in
            DashboardLiveRow(
                line: line,
                resetClaim: container.resetClaim(for: account.id),
                breakdown: dataStore.usageBreakdown(for: line.descriptor),
                accountStatus: status,
                snapshotDate: dataStore.snapshots[account.id]?.refreshedAt,
                onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() }
            )
            .opacity(activeMetricID == line.id ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: line, accountID: account.id))
            .contentShape(Rectangle())
            .contextMenu {
                DashboardMenu(
                    sections: [[DashboardMenus.pin(line.id, pinned: layout.isMetricPinned(line.id))]]
                        + DashboardMenus.account(account, status: status.notice ?? status.staleness),
                    perform: perform
                )
            }
            .reorderFrame(id: line.id, in: .named(reorderSpaceName))
        }
    }

    private func perform(_ command: DashboardCommand) {
        switch command {
        case .refresh(let accountIDs):
            Task { await dataStore.refresh(providerIDs: accountIDs, force: true) }
        case .manageAccounts:
            popover.openAccounts(nil)
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .rename(let accountID):
            renaming.begin(accountID)
        case .editAccount(let accountID):
            popover.openAccounts(accountID)
        case .shareScreenshot(let accountIDs):
            shareScreenshot(accountIDs)
        case .setPinned(let metricID, let pinned):
            layout.setMetric(metricID, pinned: pinned)
        }
    }

    @discardableResult
    private func shareScreenshot(_ accountIDs: [String]) -> Bool {
        guard let live = liveFamilies().first(where: { $0.accounts.contains { accountIDs.contains($0.id) } }) else { return false }
        let accounts = live.accounts.filter { accountIDs.contains($0.id) }
        let family = DashboardFamily(id: live.id, provider: accounts[0].provider, accounts: accounts)
        guard ShareCardRenderer.share(family: family, plans: plans(for: family), appearance: colorScheme) else { return false }
        popover.shareNotice.present(true)
        return true
    }

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
                let preview = DashboardAccountRows(account: account, plan: dataStore.plan(for: account.id),
                                                   hasSiblingAccounts: family.accounts.count > 1)
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
                    DashboardAccountRows(account: account, plan: plans[account.id], hasSiblingAccounts: family.accounts.count > 1)
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
