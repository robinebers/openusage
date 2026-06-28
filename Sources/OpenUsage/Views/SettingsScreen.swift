import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The in-popover Settings screen — the popover's third mode alongside the dashboard and
/// Customize. It replaces the old separate Settings window, which forced the popover closed every
/// time it opened. Sections are Customize-style cards (caption header over a rounded card of rows)
/// so the popover keeps one visual language; controls sit on each row's trailing edge like
/// System Settings. The footer already shows the version; the release build adds an "Updates" section
/// (auto-check, beta channel, and a full-width manual check button).
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(UpdaterController.self) private var updater

    /// Launch at login goes through the system login-item registry (`SMAppService`), which is the
    /// source of truth — no shadow preference key. Registration can fail (e.g. unbundled `swift run`),
    /// so a failed flip resyncs the toggle from the actual status, logs the error, and surfaces a
    /// friendly line under the row.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    /// Surfaced under the Advanced rows when copying the path or revealing the file fails.
    @State private var logActionError: String?

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
        // Same section rhythm as the dashboard and Customize (all read the density setting).
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            section("General") {
                row("Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .settingsSwitchStyle()
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                launchAtLoginError = nil
                            } catch {
                                AppLog.error(.config, "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
                                launchAtLoginError = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                if let launchAtLoginError {
                    // Same orange inline-notice idiom as the footer's pin-denied message.
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            section("Providers") {
                ForEach(container.registry.providers) { provider in
                    providerRow(provider)
                }
            }
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
            // Dev-build only: the signed release ships an SUFeedURL (so `updater.isActive` is true);
            // dev builds and bare `swift run` don't, so this section is hidden in production.
            if !updater.isActive {
                debugSection
            }
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                // Same orange inline-notice idiom as the General section's error line.
                Text(logActionError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Debug (dev builds only)

    /// Diagnostic buttons for the Claude provider's token-refresh path. Each button writes to the
    /// file log (set Log Level to Debug in Advanced above to see the full trace, including the
    /// coordinator's touch/verify polls). Hidden in release builds via the `!updater.isActive` gate
    /// in `content`. The buttons run on the MainActor (the provider is `@MainActor`); keychain reads
    /// inside the debug methods are offloaded to a background executor to match the production
    /// refresh path and avoid freezing the popover.
    private var debugSection: some View {
        section("Debug") {
            // Plain-language note so the section isn't a wall of unlabeled buttons.
            Text("Diagnostic buttons for the Claude token-refresh path. Set Log Level to Debug above, then use Copy Log Path / Reveal in Finder to read the trace.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            logButton("Refresh Claude (full)") {
                AppLog.info(.config, "[debug] manual Claude refresh triggered")
                Task { await container.dataStore.refresh(providerID: "claude", force: true) }
            }
            logButton("Test Delegated CLI Refresh") {
                guard let claude = container.dataStore.debugProvider("claude") as? ClaudeProvider else {
                    AppLog.warn(.config, "[debug] Claude provider not found")
                    return
                }
                AppLog.info(.config, "[debug] delegated CLI refresh test triggered")
                Task { await claude.debugRunDelegatedRefresh() }
            }
            logButton("Dump Credential State") {
                guard let claude = container.dataStore.debugProvider("claude") as? ClaudeProvider else {
                    AppLog.warn(.config, "[debug] Claude provider not found")
                    return
                }
                AppLog.info(.config, "[debug] credential state dump triggered")
                Task { await claude.debugDumpCredentialState() }
            }
            logButton("Clear Failure Gate") {
                guard let claude = container.dataStore.debugProvider("claude") as? ClaudeProvider else {
                    AppLog.warn(.config, "[debug] Claude provider not found")
                    return
                }
                claude.debugClearFailureGate()
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

    private func providerRow(_ provider: Provider) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon)
                .frame(width: 18, height: 18)
            Text(provider.displayName)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { container.enablement.isEnabled(provider.id) },
                set: { container.enablement.setEnabled($0, for: provider.id) }
            ))
            .settingsSwitchStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}
