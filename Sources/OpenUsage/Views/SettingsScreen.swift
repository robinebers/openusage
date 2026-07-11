import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UserNotifications

/// The in-popover Settings screen — the popover's third mode alongside the dashboard and
/// Customize. It replaces the old separate Settings window, which forced the popover closed every
/// time it opened. Sections are Customize-style cards (caption header over a rounded card of rows)
/// so the popover keeps one visual language; controls sit on each row's trailing edge like
/// System Settings. The footer already shows the version; the release build adds an "Updates" section
/// (auto-check, beta channel, and a full-width manual check button).
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(UpdaterController.self) private var updater

    @State private var launchAtLogin = LaunchAtLoginSetting()
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    /// Surfaced under the Advanced rows when copying the path or revealing the file fails.
    @State private var logActionError: String?
    /// macOS notification authorization for OpenUsage, surfaced in the Notifications section so a
    /// warning glyph and action button can appear when alerts can't be delivered. Refreshed on appear,
    /// when a trigger turns on, and when the app becomes active again (e.g. the user returns from
    /// System Settings after re-enabling).
    private enum NotificationsAuthState { case authorized, denied, notDetermined }
    @State private var notificationsAuth: NotificationsAuthState = .authorized

    /// Fills the region the dashboard's pinned footer leaves. Same scroller treatment as Customize:
    /// the overlay scroller stays (the scroll edge effect needs it) but is invisible.
    var body: some View {
        PopoverScrollView {
            content
        }
    }

    private var content: some View {
        @Bindable var store = container.dataStore
        @Bindable var layout = container.layout
        @Bindable var updater = updater
        @Bindable var transparency = container.transparency
        @Bindable var notifications = container.notificationSettings
        // Same section rhythm as the dashboard and Customize (all read the density setting).
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            section("General") {
                // The dashboard's cross-provider Total Spend card; at least one enabled spend-capable
                // provider must exist, so this toggle can't conjure it up alone.
                row("Show Total Spend") {
                    Toggle("", isOn: $showTotalSpend)
                        .settingsSwitchStyle()
                }
                row("Launch at Login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                        .settingsSwitchStyle()
                }
                if let launchAtLoginError = launchAtLogin.errorMessage {
                    inlineNotice(launchAtLoginError)
                }
                // Click-to-record field; its ⓧ clears the combo and disables the shortcut.
                row("Global Shortcut") {
                    ShortcutRecorderField(name: .togglePopover)
                        .hoverTooltip("Open OpenUsage from anywhere")
                }
            }
            section("Appearance") {
                row("Icon Style") {
                    picker($layout.menuBarStyle, options: MenuBarStyle.allCases, label: \.label)
                }
                row("Theme") {
                    picker($appearance, options: AppearanceSetting.allCases, label: \.label)
                        // NSApp-level so the popover panel restyles too (it ignores preferredColorScheme).
                        .onChange(of: appearance) {
                            AppearanceSetting.applyCurrent()
                        }
                }
                row("Density") {
                    picker($density, options: DensitySetting.allCases, label: \.label)
                }
                row("Time Format") {
                    picker($timeFormat, options: TimeFormatSetting.allCases, label: \.label)
                }
                // Translucent popover the proper way (behind-window vibrancy, text stays legible). It
                // yields to the system accessibility settings, and to the party easter egg while that's
                // running (the egg drives the look) — either way, see the paused notice below.
                row("Increase Transparency") {
                    Toggle("", isOn: $transparency.increaseTransparency)
                        .settingsSwitchStyle()
                        // Party mode owns the look while it's active, so disable (dim) the toggle to show
                        // it has no effect right now — its stored value resumes once the egg is exited.
                        .disabled(transparency.secretCodeActive)
                }
                // Egg first: while Party runs it overrides the toggle regardless of the system flags, so
                // its notice takes precedence over the accessibility one.
                if transparency.secretCodeActive {
                    inlineNotice("Party mode is on, so this stays paused.")
                } else if transparency.isPaused {
                    inlineNotice("macOS Reduce Transparency or Increase Contrast is on, so this stays paused.")
                }
                // Both rows surface only after the secret code has been entered. Party Mode is the egg's
                // own switch: turning it off (like re-typing the code) exits the egg and hides both rows,
                // dropping back to the base state. Drunk Mode escalates the readable party into the woozy,
                // barely-readable state and back — turning it off stays in the party (4 → 3), while turning
                // Party Mode off from there clears Drunk Mode too (4 → base).
                if transparency.secretCodeActive {
                    row("Party Mode") {
                        Toggle("", isOn: $transparency.partyModeActive)
                            .settingsSwitchStyle()
                    }
                    row("Drunk Mode") {
                        Toggle("", isOn: $transparency.drunkMode)
                            .settingsSwitchStyle()
                    }
                    // The egg yields to the accessibility flags too: when one is on the panel stays
                    // opaque, so explain why the party looks normal rather than leaving it a mystery.
                    if transparency.partyPaused {
                        inlineNotice("macOS Reduce Transparency or Increase Contrast is on, so the party stays paused.")
                    }
                }
            }
            section("Usage Display") {
                row("Show Usage As") {
                    picker($store.meterStyle, options: WidgetDisplayMode.allCases, label: \.label)
                }
                row("Reset Times") {
                    picker($store.resetDisplayMode, options: ResetDisplayMode.allCases, label: \.label)
                }
                // Off (default) leaves pacing on yellow and red only. On also surfaces projection
                // and the even-pace tick on blue rows.
                row("Always Show Pacing") {
                    Toggle("", isOn: $store.alwaysShowPacing)
                        .settingsSwitchStyle()
                        .hoverTooltip("Show how you're pacing on every metric, not just ones near their limit")
                }
            }
            notificationsSection
            section("Privacy") {
                row("Share Anonymous Usage") {
                    Toggle("", isOn: Binding(
                        get: { container.telemetry.isEnabled },
                        set: { container.telemetry.setEnabled($0) }
                    ))
                    .settingsSwitchStyle()
                }
                // Plain-language disclosure of exactly what leaves the machine — coarse counts and
                // error types only, never account details or usage values.
                Text("Shares anonymous usage counts and error types to help improve OpenUsage. No account details, credentials, or usage values are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            advancedSection
            // Visible whenever the updater is active (only the signed release build ships a feed; the
            // dev build and a bare `swift run`, with no feed, hide this).
            if updater.isActive {
                section("Updates") {
                    row("Update Automatically") {
                        Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                            .settingsSwitchStyle()
                    }
                    row("Beta Updates") {
                        Toggle("", isOn: $updater.betaChannelEnabled)
                            .settingsSwitchStyle()
                            .hoverTooltip("Receive pre-release builds before they ship to everyone")
                    }
                    // No version label here — the footer already shows it. The frame goes on the label so
                    // the glass background stretches the full row width instead of hugging the text.
                    // (Glass on macOS 26+, bordered fallback on macOS 15.)
                    Button { updater.checkForUpdates() } label: {
                        Text("Check for Updates…").frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                    .controlSize(.regular)
                    .disabled(!updater.canCheckForUpdates)
                    .padding(.horizontal, 12)
                    .padding(.vertical, density.controlRowPadding)
                }
            }
            // Mirror of the Customize cross-link — the layout controls live on the other screen.
            ScreenCrossLinkRow(
                systemImage: "slider.horizontal.3",
                title: "Customize",
                subtitle: "Choose what's visible and where",
                destination: .customize
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task { await refreshNotificationsAuth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationsAuth() }
        }
    }

    // MARK: - Notifications

    /// Quota pace notifications: three per-trigger toggles (no master switch — turn all three off to
    /// silence), each with an (i) tooltip. A warning glyph on the section header and an action row under
    /// the toggles appear when macOS permission isn't authorized and at least one trigger is on. Defaults
    /// are all off; the app requests authorization the first time a trigger is turned on.
    private var notificationsSection: some View {
        @Bindable var notifications = container.notificationSettings
        let needsAttention = notificationsAuth != .authorized && anyToggleOn
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 6) {
                Text("Notifications")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .hoverTooltip(notificationsAuth == .denied
                            ? "Notifications are turned off for OpenUsage. Enable them in System Settings."
                            : "OpenUsage needs permission to send alerts.")
                }
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                notifToggleRow(.underTenPercent, isOn: $notifications.underTenPercent)
                notifToggleRow(.healthyToClose, isOn: $notifications.healthyToClose)
                notifToggleRow(.closeToRunningOut, isOn: $notifications.closeToRunningOut)
                if needsAttention {
                    notificationsActionRow
                }
            }
            .cardSurface()
        }
        .onChange(of: anyToggleOn) { _, on in
            if on {
                // The first time a trigger is turned on, ask macOS for permission (memoized — it only
                // prompts while authorization is still not determined). Then refresh so the
                // warning/action row reflects the new status.
                AppNotifications.shared.requestAuthorization()
                Task { await refreshNotificationsAuth() }
            }
        }
    }

    /// One trigger row: the setting label, an (i) info icon with a one-sentence tooltip, and the toggle.
    private func notifToggleRow(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(milestone.settingLabel)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(milestone.tooltip)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .settingsSwitchStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// The conditional action under the toggles: a full-width "Open System Settings" button when macOS
    /// denied permission, or "Allow Notifications" when still undecided. The reason lives in the header
    /// triangle's tooltip. Shown only when a trigger is on.
    private var notificationsActionRow: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if notificationsAuth == .denied {
                    AppNotifications.shared.openSystemNotificationsSettings()
                } else {
                    AppNotifications.shared.requestAuthorization()
                    Task { await refreshNotificationsAuth() }
                }
            } label: {
                Text(notificationsAuth == .denied ? "Open System Settings" : "Allow Notifications")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        }
    }

    /// True when at least one trigger is on — the gate for the permission warning + action row.
    /// Delegates to the store's `anyEnabled` so the disjunction lives in one place.
    private var anyToggleOn: Bool {
        container.notificationSettings.anyEnabled
    }

    /// Read the live macOS authorization status into `notificationsAuth`, but only when at least one
    /// trigger is on so no warning shows while all alerts are off.
    private func refreshNotificationsAuth() async {
        guard anyToggleOn else {
            notificationsAuth = .authorized
            return
        }
        let status = await AppNotifications.shared.authorizationStatus()
        switch status {
        case .denied: notificationsAuth = .denied
        case .notDetermined: notificationsAuth = .notDetermined
        default: notificationsAuth = .authorized
        }
    }

    // MARK: - Advanced (logging)

    /// Log-level control plus copy/reveal buttons for the file log. The file lives at a fixed path
    /// (`~/Library/Logs/OpenUsage/OpenUsage.log`); raising the level here applies live (no restart) and
    /// persists across launches. Default Info, Debug is opt-in.
    private var advancedSection: some View {
        section("Advanced") {
            row("Log Level") {
                picker($logLevel, options: LogLevelSetting.allCases, label: \.label)
                    .onChange(of: logLevel) {
                        // Apply the new floor to the file sink immediately, then record the transition.
                        AppLog.reloadLevel()
                        AppLog.info(.config, "Log level changed to \(logLevel.rawValue)")
                    }
            }
            logButton("Copy Log Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(LogFile.url.path, forType: .string) else {
                    logActionError = "Couldn't copy the log path to the clipboard."
                    AppLog.warn(.config, "Copy log path failed")
                    return
                }
                logActionError = nil
            }
            logButton("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                logActionError = nil
            }
            if let logActionError {
                inlineNotice(logActionError)
            }
        }
    }

    /// A full-width glass button row, matching the "Check for Updates…" idiom.
    /// Glass on macOS 26+, bordered fallback on macOS 15.
    private func logButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    // MARK: - Section / row scaffolding

    /// A caption header over a rounded card of rows — the Customize block shape. The header is
    /// inset 8pt so it aligns with the rows' content, matching how Customize lines its provider
    /// headers up with the card rows.
    private func section(
        _ title: String,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                rows()
            }
            .cardSurface()
        }
    }

    /// One settings row: label on the leading edge, the control on the trailing edge. Same insets
    /// as a Customize metric row so the cards share one rhythm.
    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// An inline orange caption under a row — the single definition of the notice idiom shared by the
    /// General/Advanced error lines and the "this setting is paused" captions (Increase Transparency
    /// paused by a system accessibility setting, or by Party mode taking over the look).
    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A trailing popup picker that hugs its selection — segmented controls don't fit the 320pt
    /// popover once options have real words in them.
    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
