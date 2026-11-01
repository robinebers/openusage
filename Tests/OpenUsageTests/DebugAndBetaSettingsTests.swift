import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DebugAndBetaSettingsTests: QuietWindowTestCase {
    func testAdvancedShowsLogLevelWithTheChoiceSavedByZeroSevenSixteen() async throws {
        let defaults = isolatedDefaults()
        defaults.set("warn", forKey: "logLevel")

        let host = showAdvancedSettings(defaults: defaults)

        try await waitUntil { popUpTitles(in: host) == ["Warning"] }
    }

    func testLogLevelStartsAtInfo() async throws {
        let host = showAdvancedSettings(defaults: isolatedDefaults())

        try await waitUntil { popUpTitles(in: host) == ["Info"] }
    }

    func testBetaUpdatesReadsTheChoiceSavedByZeroSevenSixteen() {
        let key = "betaUpdatesEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(UpdaterController().betaChannelEnabled)

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UpdaterController().betaChannelEnabled)
    }

    private func showAdvancedSettings(defaults: UserDefaults) -> NSView {
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults
        )
        container.popover.screen = .settings
        container.popover.settingsTab = .advanced
        let view = SettingsScreen()
            .defaultAppStorage(defaults)
            .environment(container)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController())
        return show(view, in: .borderless, size: CGSize(width: PanelMetrics.width, height: 700)).host
    }

    private func popUpTitles(in view: NSView) -> [String] {
        if view is NSPopUpButton {
            return view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        }
        return view.subviews.flatMap(popUpTitles)
    }
}
