import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DisplaySettingsTests: QuietWindowTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    }

    override func tearDown() {
        NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface")
        super.tearDown()
    }

    func testPriorityIconsLeadsTheDisplayTab() async throws {
        let (container, window, host) = showSettings(.display)
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
        try await waitUntil { headingsAndPickers(in: host).count >= 6 }
        XCTAssertEqual(headingsAndPickers(in: host).prefix(6),
                       ["Priority", container.dataStore.menuBarLimit.label, "30% left", "10% left",
                        "Appearance", AppearanceSetting.system.label],
                       "one Priority heading over the menu bar picker, Warning, and Critical, then Appearance and its Theme picker")
        XCTAssertFalse(texts(in: host).contains { $0.hasPrefix("OpenUsage intelligently displays") }, "no note under Priority")
    }

    func testEachDisplayRowExplainsItselfInAnInfoTooltipInsteadOfASecondLine() async throws {
        try await assertExplainedByInfoIcons(.display, [
            "When a limit turns into a priority", "When a limit turns critically low", "Will run out before it resets",
            "Over 50% left a day before its reset", "Where usage would be at an even pace",
        ])
    }

    func testEachAlertExplainsItselfInAnInfoTooltipInsteadOfASecondLine() async throws {
        try await assertExplainedByInfoIcons(.alerts, [
            "Alert when a limit drops critically low", "Alert when a limit requires your attention",
            "A limit may run out before its reset", "Over 50% left a day before its reset",
        ])
    }

    private func assertExplainedByInfoIcons(_ tab: SettingsTab, _ explainers: [String], line: UInt = #line) async throws {
        let (_, window, host) = showSettings(tab)
        defer { window.close() }
        func tips(in element: Any) -> [String] {
            guard let node = element as? NSObject else { return [] }
            let tip = node.value(forKey: "accessibilityHelp") as? String
            return [tip].compactMap { $0 }.filter { !$0.isEmpty }
                + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(tips)
        }
        try await waitUntil { Set(explainers).isSubset(of: tips(in: host)) }
        XCTAssertEqual(tips(in: host).filter(explainers.contains), explainers, "each row's info icon carries what it does, in order", line: line)
        XCTAssertTrue(Set(texts(in: host)).isDisjoint(with: explainers), "no explainer shows as a second line", line: line)
    }

    private func showSettings(_ tab: SettingsTab) -> (AppContainer, NSWindow, NSView) {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        container.popover.screen = .settings
        container.popover.settingsTab = tab
        let settings = SettingsScreen()
            .defaultAppStorage(defaults)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController())
        let (window, host) = show(settings, size: CGSize(width: PanelMetrics.width, height: 900))
        return (container, window, host)
    }

    private func texts(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
            ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
        return [text].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(texts)
    }
}
