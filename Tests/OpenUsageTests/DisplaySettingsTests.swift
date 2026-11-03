import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DisplaySettingsTests: QuietWindowTestCase {
    func testPriorityIconsLeadsTheDisplayTab() async throws {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        container.popover.screen = .settings
        container.popover.settingsTab = .display
        let settings = SettingsScreen()
            .defaultAppStorage(defaults)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController())
        let (window, host) = show(settings, size: CGSize(width: PanelMetrics.width, height: 900))
        defer { window.close() }
        func popUps(in view: NSView) -> [NSPopUpButton] {
            [view as? NSPopUpButton].compactMap { $0 } + view.subviews.flatMap(popUps)
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return popUps(in: host).count == 5
        }
        let topDown = popUps(in: host).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        XCTAssertEqual(topDown.prefix(2).map(\.title), [container.dataStore.menuBarLimit.label, AppearanceSetting.system.label],
                       "Show In Menu Bar, then Appearance's Theme")
    }
}
