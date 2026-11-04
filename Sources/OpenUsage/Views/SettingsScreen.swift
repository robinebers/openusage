import KeyboardShortcuts
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(DashboardTab.defaultKey) private var defaultTab = DashboardTab.priority
    @AppStorage(PaceMilestone.critical.settingKey) private var criticalAlert = false
    @AppStorage(PaceMilestone.warning.settingKey) private var warningAlert = false
    @AppStorage(PaceMilestone.closeToRunningOut.settingKey) private var closeToRunningOut = false
    @AppStorage(PaceMilestone.useItOrLoseIt.settingKey) private var useItOrLoseIt = false
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.info
    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @State private var notificationsDenied = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// How far a grouped `Form` already sets its cards in from every edge.
    private static let formRowInset: CGFloat = 20

    var body: some View {
        Form {
            switch popover.settingsTab {
            case .general: generalTab
            case .display: displayTab
            case .alerts: alertsTab
            case .advanced: advancedTab
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .contentMargins(.top, DashboardContentView.barGap - Self.formRowInset, for: .scrollContent)
        .contentMargins(.bottom, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .scrollPosition($scrollPosition)
        .onChange(of: popover.settingsTab) { scrollPosition.scrollTo(edge: .top) }
        .onChange(of: popover.screen, initial: true) { _, screen in
            if screen == .settings {
                scrollPosition.scrollTo(edge: .top)
                launchAtLogin.refreshStatus()
                commandLineTool.refreshStatus()
                if criticalAlert || warningAlert || closeToRunningOut || useItOrLoseIt { checkNotificationPermission() }
            }
        }
    }

    @ViewBuilder
    private var generalTab: some View {
        Section {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.update(to: $0) }
            ))
            picker("Default Tab", selection: $defaultTab, options: DashboardTab.allCases.map { ($0, $0.label) })
            LabeledContent("Global Shortcut") {
                KeyboardShortcuts.Recorder(for: .togglePopover)
                    .disabled(popover.screen != .settings)
            }
        } footer: {
            if let errorMessage = launchAtLogin.errorMessage {
                SettingsNote(errorMessage, isWarning: true)
            }
        }
        .onChange(of: defaultTab) { _, newValue in popover.dashboardTab = newValue }
        updatesSection
    }

    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        Section("Updates") {
            Toggle("Check Automatically", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isActive)
            Toggle("Beta Updates", isOn: $updater.betaChannelEnabled)
                .disabled(!updater.isActive)
            HStack {
                Spacer(minLength: 0)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    @ViewBuilder
    private var displayTab: some View {
        @Bindable var dataStore = dataStore
        Section {
            PriorityIconsPreview()
            picker("Show In Menu Bar", selection: $dataStore.menuBarLimit, options: MenuBarLimit.allCases.map { ($0, $0.label) })
        } header: {
            Text("Priority Icons")
        } footer: {
            SettingsNote("OpenUsage intelligently displays the usage icons at risk of running out and that require your attention.")
        }
        Section("Priority Limits") {
            levelPicker("Warning", subtitle: "Turns a limit orange", severity: .warning,
                        selection: $dataStore.priorityLimits.warning, options: PriorityLimits.warningOptions)
            levelPicker("Critical", subtitle: "Turns a limit red", severity: .critical,
                        selection: $dataStore.priorityLimits.critical, options: PriorityLimits.criticalOptions)
            Toggle(isOn: $dataStore.showsBurningFast) {
                limitLabel("Burning Fast", subtitle: "Will run out before it resets") {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.severityColor(.warning))
                }
            }
            Toggle(isOn: $dataStore.showsUseItOrLoseIt) {
                limitLabel("Use It or Lose It", subtitle: PaceMilestone.useItOrLoseIt.settingSubtitle(dataStore.priorityLimits)) {
                    Image(systemName: "hourglass.tophalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.severityColor(.normal))
                }
            }
        }
        Section("Appearance") {
            picker("Theme", selection: $appearance, options: AppearanceSetting.allCases.map { ($0, $0.label) })
                .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
            picker("Time Format", selection: $timeFormat, options: TimeFormatSetting.allCases.map { ($0, $0.label) })
        }
        Section("Usage") {
            picker("Show Usage As", selection: $dataStore.meterStyle, options: WidgetDisplayMode.allCases.map { ($0, $0.label) })
            picker("Reset Times", selection: $dataStore.resetDisplayMode, options: ResetDisplayMode.allCases.map { ($0, $0.label) })
        }
    }

    private var alertsTab: some View {
        Section {
            notificationToggle(.critical, isOn: $criticalAlert)
            notificationToggle(.warning, isOn: $warningAlert)
            notificationToggle(.closeToRunningOut, isOn: $closeToRunningOut)
            notificationToggle(.useItOrLoseIt, isOn: $useItOrLoseIt)
        } header: {
            Text("Notifications")
        } footer: {
            if notificationsDenied {
                Text("Notifications are off for OpenUsage in [System Settings](x-apple.systempreferences:com.apple.Notifications-Settings.extension).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.notice)
            }
        }
    }

    @ViewBuilder
    private var advancedTab: some View {
        @Bindable var hideFromScreenShare = container.hideFromScreenShare
        Section {
            Toggle("Hide From Screen Share", isOn: $hideFromScreenShare.isEnabled)
            Toggle("Help Make OpenUsage Better", isOn: Binding(
                get: { container.telemetry.isEnabled },
                set: { container.telemetry.setEnabled($0) }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsNote("While your screen is shared or recorded, the menu bar shows the app icon instead of your usage.")
                SettingsNote("Share additional anonymous usage stats that tell the team where to improve.")
            }
        }
        Section {
            LabeledContent("Terminal Helper") {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled, .linkedToAnotherCopy:
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
                SettingsNote("Adds a global `openusage` command that prints the usage the app last fetched.")
                if commandLineTool.status == .conflict {
                    SettingsNote("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.", isWarning: true)
                } else if let errorMessage = commandLineTool.errorMessage {
                    SettingsNote(errorMessage, isWarning: true)
                } else if case .linkedToAnotherCopy = commandLineTool.status {
                    SettingsNote("\(commandLineTool.destinationPath) points at another copy of OpenUsage. Install points it at this one.")
                }
            }
        }
        Section {
            picker("Log Level", selection: $logLevel, options: LogLevelSetting.allCases.map { ($0, $0.label) })
        } header: {
            Text("Debug")
        } footer: {
            SettingsNote("How much detail OpenUsage writes to the macOS log. Choose Debug while you reproduce a problem.")
        }
    }

    private func picker<Value: Hashable>(_ label: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func levelPicker(
        _ title: String, subtitle: String, severity: WidgetData.MeterSeverity, selection: Binding<Int>, options: [Int]
    ) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { Text("\($0)% left").tag($0) }
        } label: {
            limitLabel(title, subtitle: subtitle) {
                Circle().fill(Theme.severityColor(severity)).frame(width: 8, height: 8)
            }
        }
    }

    /// A Priority Limits row's label: its mark, then its title over what it does.
    private func limitLabel(_ title: String, subtitle: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 8) {
            mark().frame(width: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func notificationToggle(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(milestone.notificationTitle)
            Text(milestone.settingSubtitle(dataStore.priorityLimits))
        }
        .onChange(of: isOn.wrappedValue) { _, enabled in
            if enabled { checkNotificationPermission() }
        }
    }

    private func checkNotificationPermission() {
        Task { notificationsDenied = await !AppNotifications.shared.requestAuthorization() }
    }
}

/// Sample icons at the number the setting picks, so every choice looks different whatever is running
/// out right now. Shrunk to sit in a row however many it holds.
struct PriorityIconsPreview: View {
    @Environment(WidgetDataStore.self) private var dataStore

    private static let height: CGFloat = 30
    private static let largestScale: CGFloat = 0.85
    private static let samples: [(kind: ProviderKind, badge: String?, label: String, value: String)] = [
        (.claude, "P", "Weekly", "38%"), (.claude, "A1", "Session", "26%"), (.codex, nil, "Weekly", "31%"),
        (.cursor, nil, "Extra", "$310"), (.antigravity, nil, "Gemini", "12%"), (.grok, nil, "Weekly", "9%"),
        (.copilot, nil, "Credits", "7%"),
    ]

    static func sample(limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = samples.prefix(limit.count).enumerated().map { index, sample in
            MenuBarContent.Item(
                id: "sample.\(index)",
                provider: Provider(id: "sample.\(index)", kind: sample.kind, badge: sample.badge),
                label: sample.label,
                shortLabel: sample.label,
                value: sample.value
            )
        }
        return MenuBarContent(items: shown, overflow: samples.count - shown.count)
    }

    static func fittedSize(of strip: NSSize, in width: CGFloat) -> NSSize {
        let scale = min(largestScale, width / strip.width)
        return NSSize(width: strip.width * scale, height: strip.height * scale)
    }

    var body: some View {
        let content = Self.sample(limit: dataStore.menuBarLimit)
        let strip = MenuBarStripRenderer.image(for: content) ?? MenuBarStripRenderer.appIcon
        GeometryReader { proxy in
            let size = Self.fittedSize(of: strip.size, in: proxy.size.width)
            Image(nsImage: strip)
                .renderingMode(.template)
                .resizable()
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .accessibilityLabel("Menu Bar Preview")
    }
}

private struct SettingsNote: View {
    let text: LocalizedStringKey
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = LocalizedStringKey(text)
        self.isWarning = isWarning
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isWarning ? AnyShapeStyle(Theme.notice) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
