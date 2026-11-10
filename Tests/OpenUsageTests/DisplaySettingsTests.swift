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

    func testGeneralEndsWithAppearanceThenUpdates() async throws {
        try await assertHeadingsAndPickers(.general, [
            DashboardTab.priority.label, "Appearance", AppearanceSetting.system.label, TimeFormatSetting.auto.label, "Updates",
        ])
    }

    func testDisplayHoldsMenuBarIconsThenUsageThenUnifyAccounts() async throws {
        try await assertHeadingsAndPickers(.display, [
            "Menu Bar Icons", MenuBarLimit.upToThree.label, "Usage", WidgetDisplayMode.remaining.label, ResetDisplayMode.relative.label,
            "Unify Accounts",
        ])
    }

    func testAlertsOpensWithPriorityAboveNotifications() async throws {
        try await assertHeadingsAndPickers(.alerts, ["Priority", "30% left", "10% left", "Notifications"])
    }

    func testEachDisplayRowExplainsItselfInAnInfoTooltipInsteadOfASecondLine() async throws {
        try await assertExplainedByInfoIcons(.display, [
            "Show icons in the menu bar even if not requiring your attention yet", "Where usage would be at an even pace",
        ])
    }

    func testEachAlertExplainsItselfInAnInfoTooltipInsteadOfASecondLine() async throws {
        try await assertExplainedByInfoIcons(.alerts, [
            "When a limit turns into a priority", "When a limit turns critically low", "Will run out before it resets",
            "Over 50% left a day before its reset",
            "Alert when a limit drops critically low", "Alert when a limit requires your attention",
            "A limit may run out before its reset", "Over 50% left a day before its reset",
        ])
    }

    func testEachAdvancedRowExplainsItselfInAnInfoTooltipInsteadOfAFooterNote() async throws {
        try await assertExplainedByInfoIcons(.advanced, [
            "Hide usage and account names from screenshots and recordings", "Share additional anonymous usage stats that tell the team where to improve.",
            "Adds a global openusage command that prints the usage the app last fetched.", "How much detail OpenUsage writes to the macOS log. Choose Debug while you reproduce a problem.",
        ])
    }

    func testUnifyAccountsHasASwitchForClaudeAndChatGPTThatTheProviderMenuSharesAndThatIsSaved() async throws {
        let defaults = isolatedDefaults()
        let (container, window, host) = showSettings(.display, defaults: defaults)
        defer { window.close() }
        func nodes(in element: Any) -> [NSObject] {
            guard let node = element as? NSObject else { return [] }
            return [node] + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(nodes)
        }
        func unifySwitches() -> [(label: String, isOn: Bool, node: NSObject)] {
            let all = nodes(in: host)
            guard let heading = all.firstIndex(where: { $0.value(forKey: "accessibilityLabel") as? String == "Unify Accounts" }) else { return [] }
            let rows = all[(heading + 1)...]
            return zip(rows, rows.dropFirst()).compactMap { title, control in
                guard control.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.checkBox.rawValue,
                      let label = title.value(forKey: "accessibilityValue") as? String else { return nil }
                return (label, (control.value(forKey: "accessibilityValue") as? NSNumber)?.boolValue == true, control)
            }
        }
        try await waitUntil { unifySwitches().count == 2 }
        XCTAssertEqual(unifySwitches().map(\.label), ["Claude", "ChatGPT"])
        XCTAssertEqual(unifySwitches().map(\.isOn), [false, false], "both start off")

        container.layout.setUnifiesAccounts(true, of: .claude)
        try await waitUntil { unifySwitches().map(\.isOn) == [true, false] }

        unifySwitches()[1].node.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await waitUntil { container.layout.unifiesAccounts(of: .codex) }
        XCTAssertEqual(LayoutStore(registry: container.layout.registry, defaults: defaults).state.unifiedProviderKinds, [.claude, .codex],
                       "the menu and the switch save one setting")
    }

    private func assertHeadingsAndPickers(_ tab: SettingsTab, _ expected: [String], line: UInt = #line) async throws {
        let (_, window, host) = showSettings(tab)
        defer { window.close() }
        try await waitUntil { self.headingsAndPickers(in: host).count >= expected.count }
        XCTAssertEqual(headingsAndPickers(in: host), expected, "\(tab)'s headings and pickers, in order", line: line)
        XCTAssertFalse(texts(in: host).contains { $0.hasPrefix("OpenUsage intelligently displays") }, "no note under Menu Bar Icons", line: line)
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

    private func showSettings(_ tab: SettingsTab, defaults: UserDefaults? = nil) -> (AppContainer, NSWindow, NSView) {
        let defaults = defaults ?? isolatedDefaults()
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

    private func headingsAndPickers(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let entry: String? = switch node.value(forKey: "accessibilityRole") as? String {
        case "AXHeading": node.value(forKey: "accessibilityLabel") as? String
        case NSAccessibility.Role.popUpButton.rawValue: node.value(forKey: "accessibilityValue") as? String
        default: nil
        }
        return [entry].compactMap { $0 } + children(of: node).flatMap(headingsAndPickers)
    }

    /// Skips text fields: walking into the Global Shortcut recorder's search field aborts the test process.
    private func children(of node: NSObject) -> [Any] {
        guard node.value(forKey: "accessibilityRole") as? String != NSAccessibility.Role.textField.rawValue else { return [] }
        return node.value(forKey: "accessibilityChildren") as? [Any] ?? []
    }

    private func texts(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
            ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
        return [text].compactMap { $0 } + children(of: node).flatMap(texts)
    }
}
