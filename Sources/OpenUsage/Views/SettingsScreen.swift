import SwiftUI

struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(PaceMilestone.underTenPercent.settingKey) private var underTenPercent = false
    @AppStorage(PaceMilestone.healthyToClose.settingKey) private var healthyToClose = false
    @AppStorage(PaceMilestone.closeToRunningOut.settingKey) private var closeToRunningOut = false
    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                section("General") {
                    row("Launch at Login") {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.update(to: $0) }
                        ))
                        .settingsSwitchStyle()
                    }
                    row("Global Shortcut") {
                        ShortcutRecorderField(name: .togglePopover, isVisible: popover.screen == .settings)
                    }
                }
                section("Appearance") {
                    row("Theme") {
                        picker($appearance, options: AppearanceSetting.allCases, label: \.label)
                            .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
                    }
                    row("Time Format") {
                        picker($timeFormat, options: TimeFormatSetting.allCases, label: \.label)
                    }
                }
                usageDisplaySection
                notificationsSection
                privacySection
                commandLineSection
                updatesSection
            }
            .padding(PanelMetrics.margin)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: popover.screen) { _, screen in
            if screen == .settings {
                scrollPosition.scrollTo(edge: .top)
                launchAtLogin.refreshStatus()
                commandLineTool.refreshStatus()
            }
        }
    }

    /// How every bounded reading and reset time reads, on the dashboard and in the menu bar.
    private var usageDisplaySection: some View {
        @Bindable var dataStore = dataStore
        return section("Usage Display") {
            row("Show Usage As") {
                picker($dataStore.meterStyle, options: WidgetDisplayMode.allCases, label: \.label)
            }
            row("Reset Times") {
                picker($dataStore.resetDisplayMode, options: ResetDisplayMode.allCases, label: \.label)
            }
        }
    }

    private var notificationsSection: some View {
        section("Notifications") {
            notificationRow("Under 10% Remaining", isOn: $underTenPercent)
            notificationRow("Healthy Pace Changes", isOn: $healthyToClose)
            notificationRow("Near-Limit Pace Changes", isOn: $closeToRunningOut)
        }
    }

    private var privacySection: some View {
        section("Privacy") {
            row("Help Make OpenUsage Better") {
                Toggle("", isOn: Binding(
                    get: { container.telemetry.isEnabled },
                    set: { container.telemetry.setEnabled($0) }
                ))
                .settingsSwitchStyle()
            }
            // Daily activity and crash reports are always on; the toggle only gates extra analytics.
            Text("Share additional anonymous usage stats that tell the team where to improve.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandLineSection: some View {
        section("Command Line") {
            row("Terminal Helper") {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Adds a global `openusage` command that prints the usage the app last fetched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if commandLineTool.status == .conflict {
                inlineNotice("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
            } else if let errorMessage = commandLineTool.errorMessage {
                inlineNotice(errorMessage)
            }
        }
    }

    /// Visible whenever the updater is active (only the signed release build ships a feed; the dev
    /// build and a bare `swift run`, with no feed, hide this).
    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        if updater.isActive {
            section("Updates") {
                row("Check Automatically") {
                    Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                        .settingsSwitchStyle()
                }
                row("Beta Updates") {
                    Toggle("", isOn: $updater.betaChannelEnabled)
                        .settingsSwitchStyle()
                }
                // No version label here; the footer already shows it. The frame goes on the label so
                // the glass background stretches the full row width instead of hugging the text.
                Button { updater.checkForUpdates() } label: {
                    Text("Check for Updates…").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .controlSize(.regular)
                .disabled(!updater.canCheckForUpdates)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
            }
        }
    }

    private func notificationRow(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle("", isOn: isOn)
                .settingsSwitchStyle()
                .onChange(of: isOn.wrappedValue) { _, enabled in
                    if enabled { AppNotifications.shared.requestAuthorization() }
                }
        }
    }

    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PanelMetrics.headerSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0, content: content)
                .cardSurface()
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }

    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
