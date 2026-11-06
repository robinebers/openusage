import AppKit
import SwiftUI

struct PopoverFooter: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    @Environment(\.colorScheme) private var colorScheme
    let screen: PopoverScreen

    @ViewBuilder
    var body: some View {
        Group {
            if screen == .dashboard {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    #if OPENUSAGE_DEVELOPMENT
                    DemoDataLabel()
                    #endif
                    Spacer(minLength: 8)
                    if popover.dashboardTab == .priority, liveBoard.hasRows { copyPriorityButton }
                    optionsMenu
                }
                .padding(.horizontal, 4)
            } else if screen == .accounts, popover.customizeProviderID == nil, popover.customizeHubID == nil {
                addAccountButton
            } else {
                EmptyView()
            }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, PanelMetrics.margin)
        .padding(.top, DashboardContentView.barGap)
        .padding(.bottom, PanelMetrics.margin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if screen == .dashboard, popover.shareNotice.value {
                shareCopiedPill
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: popover.shareNotice.value)
        .animation(Motion.spring, value: popover.shareNotice.trigger)
    }

    private var addAccountButton: some View {
        Button { popover.isAddingAccount = true } label: {
            Text("Add New Account")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var liveBoard: PriorityBoard {
        dataStore.priorityBoard(in: layout.displayGroups, pinned: layout.state.priorityPinIDs, now: Date(), hidingEmails: !container.hideFromScreenShare.isEnabled)
    }

    /// Copies the Priority tab as a picture. It reads the live board when clicked.
    private var copyPriorityButton: some View {
        Button {
            guard ShareCardRenderer.copy(PriorityShareCard(
                board: liveBoard, now: Date(), appearance: colorScheme, blursAccountNames: container.hideFromScreenShare.isEnabled
            ), named: "priority") else { return }
            popover.shareNotice.present(true)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy Priority Screenshot")
    }

    /// The Options pull-down behind a round button. Check for Updates… stays listed on every build and
    /// disables itself while Sparkle can't check: a dev build with no feed, or a check already running.
    /// Accounts and Settings carry their key equivalents
    /// only as labels: while the menu is closed `PopoverKeyReader` handles (and consumes) them first, so
    /// they can't double-fire. ⌘Q is unowned elsewhere, so it rides its menu item directly.
    private var optionsMenu: some View {
        Menu {
            Button { popover.toggle(.accounts) } label: {
                Label("Accounts", systemImage: "person.crop.circle")
            }
            .keyboardShortcut(.return, modifiers: [])

            Button { popover.toggle(.settings) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Divider()

            Button { updater.checkForUpdates() } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Link(destination: URL(string: "https://github.com/robinebers/openusage/issues/new/choose")!) {
                Label("Report an Issue…", systemImage: "ladybug")
            }

            Button { AboutPanel.present() } label: {
                Label("About OpenUsage", systemImage: "info.circle")
            }
            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Label("Quit OpenUsage", systemImage: "power")
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options")
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: "Copied to clipboard",
            tint: Theme.positive,
            trigger: popover.shareNotice.trigger
        )
    }

    /// The version over the refresh countdown, as 0.7 showed them.
    private var footerIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if !layout.displayGroups.isEmpty { nextUpdateButton }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(updateStatusText(now: context.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if isUpdating {
                        MotionAwareProgressView(controlSize: .mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private var isUpdating: Bool {
        !dataStore.refreshingProviderIDs.isEmpty
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await dataStore.refreshAll(force: true) }
    }

    private func updateStatusText(now: Date) -> String {
        if isUpdating { return "Updating…" }
        let base = dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(RefreshSetting.interval).timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded(.up))
        if totalSeconds >= 60 {
            let minutes = Int((Double(totalSeconds) / 60).rounded(.up))
            return "Next update in \(minutes)m"
        }
        return "Next update in \(totalSeconds)s"
    }
}
