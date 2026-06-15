import AppKit
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI

/// The in-popover Settings screen — the popover's third mode alongside the dashboard and
/// Customize. It replaces the old separate Settings window, which forced the popover closed every
/// time it opened. Sections are Customize-style cards (caption header over a rounded card of rows)
/// so the popover keeps one visual language; controls sit on each row's trailing edge like
/// System Settings. The footer already shows the version; the release build adds an "Updates" section
/// (auto-check, beta channel, and a full-width manual check button).
struct SettingsScreen: View {
    private static let logger = Logger(subsystem: "OpenUsage", category: "Settings")

    @Environment(AppContainer.self) private var container
    @Environment(UpdaterController.self) private var updater
    /// Reported up so `DashboardView` can fit the popover to the settings content (clamped there).
    @Binding var contentHeight: CGFloat
    @Binding var hasMeasuredContent: Bool

    /// Launch at login goes through the system login-item registry (`SMAppService`), which is the
    /// source of truth — no shadow preference key. Registration can fail (e.g. unbundled `swift run`),
    /// so a failed flip resyncs the toggle from the actual status, logs the error, and surfaces a
    /// friendly line under the row.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage(RefreshSetting.key) private var refreshMinutes = RefreshSetting.defaultMinutes
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Fills the region the dashboard's pinned footer leaves; reports its content height up so
    /// `DashboardView` can fit the popover to it (`settingsScrollHeight`). Same scroller treatment
    /// as Customize: the overlay scroller stays (the scroll edge effect needs it) but is invisible.
    var body: some View {
        MeasuredScrollScreen(onMeasure: { newValue in
            if newValue > 0 {
                contentHeight = newValue
                hasMeasuredContent = true
            }
        }) {
            content
        }
        .onAppear {
            // The menu-bar panel never activates the app on its own, and an inactive accessory
            // app receives no text input — the shortcut recorder field would silently ignore
            // clicks. Activating on entry gives the screen's only text control a working focus
            // path; the panel itself is already the key window.
            NSApp.activate()
        }
    }

    private var content: some View {
        @Bindable var store = container.dataStore
        @Bindable var layout = container.layout
        @Bindable var updater = updater
        // Same section rhythm as the dashboard and Customize (all read the density setting).
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            section("Startup") {
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
                                Self.logger.error(
                                    "Launch at Login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                                )
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
                        .help("Open OpenUsage from anywhere")
                }
            }
            section("Appearance") {
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
            }
            section("Menu Bar") {
                row("Style") {
                    picker($layout.menuBarStyle, options: MenuBarStyle.allCases, label: \.label)
                }
                row("Refresh Every") {
                    picker($refreshMinutes, options: RefreshSetting.allowedMinutes, label: { "\($0) minutes" })
                }
            }
            section("Providers") {
                ForEach(container.registry.providers) { provider in
                    providerRow(provider)
                }
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
                            .help("Receive pre-release builds before they ship to everyone")
                    }
                    // No version label here — the footer already shows it. The frame goes on the label so
                    // the glass background stretches the full row width instead of hugging the text.
                    Button { updater.checkForUpdates() } label: {
                        Text("Check for Updates…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
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
