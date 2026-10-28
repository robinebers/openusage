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
            Form {
                Section("General") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                    LabeledContent("Global Shortcut") {
                        ShortcutRecorderField(name: .togglePopover, isVisible: popover.screen == .settings)
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
                    Picker("Time Format", selection: $timeFormat) {
                        ForEach(TimeFormatSetting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                usageDisplaySection
                notificationsSection
                privacySection
                commandLineSection
                updatesSection
            }
            .inlineGroupedForm()
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

    private var usageDisplaySection: some View {
        @Bindable var dataStore = dataStore
        return Section("Usage Display") {
            Picker("Show Usage As", selection: $dataStore.meterStyle) {
                ForEach(WidgetDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Reset Times", selection: $dataStore.resetDisplayMode) {
                ForEach(ResetDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            notificationToggle("Under 10% Remaining", isOn: $underTenPercent)
            notificationToggle("Healthy Pace Changes", isOn: $healthyToClose)
            notificationToggle("Near-Limit Pace Changes", isOn: $closeToRunningOut)
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Help Make OpenUsage Better", isOn: Binding(
                get: { container.telemetry.isEnabled },
                set: { container.telemetry.setEnabled($0) }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            Text("Share additional anonymous usage stats that tell the team where to improve.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var commandLineSection: some View {
        Section {
            LabeledContent("Terminal Helper") {
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
        } header: {
            Text("Command Line")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adds a global `openusage` command that prints the usage the app last fetched.")
                    .foregroundStyle(.secondary)
                if commandLineTool.status == .conflict {
                    Text("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
                        .foregroundStyle(Theme.notice)
                } else if let errorMessage = commandLineTool.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(Theme.notice)
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        if updater.isActive {
            Section("Updates") {
                Toggle("Check Automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Beta Updates", isOn: $updater.betaChannelEnabled)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private func notificationToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, enabled in
                if enabled { AppNotifications.shared.requestAuthorization() }
            }
    }
}
