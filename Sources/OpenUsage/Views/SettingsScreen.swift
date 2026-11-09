import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsScreen: View {
    var openURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

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
                SettingsNote(errorMessage)
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
            picker("Max Items In Menu Bar", selection: $dataStore.menuBarLimit, options: MenuBarLimit.allCases.map { ($0, $0.label) })
            Toggle(isOn: $dataStore.menuBarAlwaysShows) {
                titled("Always Show In Menu Bar", info: "Show icons in the menu bar even if not requiring your attention yet")
            }
            .disabled(dataStore.menuBarLimit == .iconOnly)
        } header: {
            Text("Priority")
        }
        Section {
            levelPicker("Warning", info: "When a limit turns into a priority", severity: .warning,
                        selection: $dataStore.priorityLimits.warning, options: PriorityLimits.warningOptions)
            levelPicker("Critical", info: "When a limit turns critically low", severity: .critical,
                        selection: $dataStore.priorityLimits.critical, options: PriorityLimits.criticalOptions)
            Toggle(isOn: $dataStore.showsBurningFast) {
                limitLabel("Burning Fast", info: "Will run out before it resets") {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.severityColor(.warning))
                }
            }
            Toggle(isOn: $dataStore.showsUseItOrLoseIt) {
                limitLabel("Use It or Lose It", info: PaceMilestone.useItOrLoseIt.settingSubtitle) {
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
            Toggle(isOn: $dataStore.showsPaceMarks) {
                titled("Pace Marks", info: "Where usage would be at an even pace")
            }
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
                notificationSettingsButton
            }
        }
    }

    var notificationSettingsButton: some View {
        Button {
            openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)")!)
            (NSApp.keyWindow as? MenuBarPanel)?.onDismiss?()
        } label: {
            Text("Notifications are off for OpenUsage in \(Text("System Settings").foregroundColor(.accentColor)).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.notice)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var advancedTab: some View {
        @Bindable var hideFromScreenShare = container.hideFromScreenShare
        #if OPENUSAGE_DEVELOPMENT
        DevelopmentDataSettings()
        #endif
        Section {
            Toggle(isOn: $hideFromScreenShare.isEnabled) {
                titled("Privacy Mode", info: "Hide usage and account names from screenshots and recordings")
            }
            Toggle(isOn: Binding(
                get: { container.telemetry.isEnabled },
                set: { container.telemetry.setEnabled($0) }
            )) {
                titled("Help Make OpenUsage Better", info: "Share additional anonymous usage stats that tell the team where to improve.")
            }
        } header: {
            Text("Privacy")
        }
        Section {
            LabeledContent {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled, .linkedToAnotherCopy:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            } label: {
                titled("Terminal Helper", info: "Adds a global openusage command that prints the usage the app last fetched.")
            }
        } header: {
            Text("Command Line")
        } footer: {
            if commandLineTool.status == .conflict {
                SettingsNote("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
            } else if let errorMessage = commandLineTool.errorMessage {
                SettingsNote(errorMessage)
            } else if case .linkedToAnotherCopy = commandLineTool.status {
                SettingsNote("\(commandLineTool.destinationPath) points at another copy of OpenUsage. Install points it at this one.")
            }
        }
        Section {
            Picker(selection: $logLevel) {
                ForEach(LogLevelSetting.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                titled("Log Level", info: "How much detail OpenUsage writes to the macOS log. Choose Debug while you reproduce a problem.")
            }
        } header: {
            Text("Debug")
        }
    }

    private func picker<Value: Hashable>(_ label: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func levelPicker(
        _ title: String, info: String, severity: WidgetData.MeterSeverity, selection: Binding<Int>, options: [Int]
    ) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { Text("\($0)% left").tag($0) }
        } label: {
            limitLabel(title, info: info) {
                Circle().fill(Theme.severityColor(severity)).frame(width: 8, height: 8)
            }
        }
    }

    /// A Priority limit row's label: its mark, then its title with what it does behind an info icon.
    private func limitLabel(_ title: String, info: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 8) {
            mark().frame(width: 8)
            titled(title, info: info)
        }
    }

    /// A row's title followed by an info icon that shows what the row does on hover.
    private func titled(_ title: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .hoverTooltip(info)
        }
    }

    private func notificationToggle(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            titled(milestone.notificationTitle, info: milestone.settingSubtitle)
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

    init(_ text: String) {
        self.text = LocalizedStringKey(text)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.notice)
            .fixedSize(horizontal: false, vertical: true)
    }
}
