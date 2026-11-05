import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DisplaySettingsTests: QuietWindowTestCase {
    func testPriorityIconsLeadsTheDisplayTab() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
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
        func headingsAndPickers(in element: Any) -> [String] {
            guard let node = element as? NSObject else { return [] }
            let entry: String? = switch node.value(forKey: "accessibilityRole") as? String {
            case "AXHeading": node.value(forKey: "accessibilityLabel") as? String
            case NSAccessibility.Role.popUpButton.rawValue: node.value(forKey: "accessibilityValue") as? String
            default: nil
            }
            return [entry].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(headingsAndPickers)
        }
        try await waitUntil { headingsAndPickers(in: host).count >= 7 }
        XCTAssertEqual(headingsAndPickers(in: host).prefix(7),
                       ["Priority Icons", container.dataStore.menuBarLimit.label, "Priority Limits", "30% left", "10% left",
                        "Appearance", AppearanceSetting.system.label],
                       "Priority Icons and its picker, Priority Limits' Warning and Critical, then Appearance and its Theme picker")

        func texts(in element: Any) -> [String] {
            guard let node = element as? NSObject else { return [] }
            let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
                ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
            return [text].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(texts)
        }
        let subtitles = ["Turns a limit orange", "Turns a limit red", "Will run out before it resets", "Over 50% left a day before its reset"]
        try await waitUntil { Set(subtitles).isSubset(of: texts(in: host)) }
        XCTAssertEqual(texts(in: host).filter(subtitles.contains), subtitles, "each Priority Limits row says what it does under its title")
    }
}
