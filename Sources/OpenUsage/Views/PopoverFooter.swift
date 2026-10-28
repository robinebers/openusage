import AppKit
import SwiftUI

/// A screen's footer chrome: app identity, refresh status, dashboard actions, and copy confirmation.
/// It uses the screen it belongs to, so during a slide each mounted page draws its own footer.
struct PopoverFooter: View {
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    let screen: PopoverScreen
    let horizontalPadding: CGFloat
    let onHeightChange: (PopoverScreen, CGFloat) -> Void

    @ViewBuilder
    var body: some View {
        Group {
            if screen == .accounts {
                EmptyView()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    if screen == .dashboard {
                        optionsMenu
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .barGlass()
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
            onHeightChange(screen, height)
        }
        .overlay(alignment: .top) {
            if screen == .dashboard, popover.shareNotice.value {
                shareCopiedPill
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: popover.shareNotice.value)
        .animation(Motion.spring, value: popover.shareNotice.trigger)
    }

    /// The Options pull-down on one glass capsule. The system `.buttonStyle(.glass)` renders flat on a
    /// `Menu`, so `.menuStyle(.button)` + `.buttonStyle(.plain)` strip the menu chrome and
    /// `interactiveGlass` owns the surface. Accounts and Settings carry their key equivalents only as
    /// labels: while the menu is closed `PopoverKeyReader` handles (and consumes) them first, so they
    /// can't double-fire. ⌘Q is unowned elsewhere, so it rides its menu item directly.
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
            HStack(spacing: 5) {
                Text("Options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .interactiveGlass(in: Capsule())
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: "Copied to clipboard",
            tint: Theme.positive,
            trigger: popover.shareNotice.trigger
        )
    }

    private var footerIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if let notice = popover.pinNotice.value {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    .denyShake(trigger: popover.pinNotice.trigger, shakeOnAppear: true)
            } else {
                nextUpdateButton
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(Motion.spring, value: popover.pinNotice.value)
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
