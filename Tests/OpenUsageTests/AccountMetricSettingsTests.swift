import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class AccountMetricSettingsTests: QuietWindowTestCase {
    func testHidingAndReorderingAnAccountsMetricsSurvivesARestart() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(registry: .mock, defaults: defaults)

        XCTAssertTrue(store.setMetric("claude.weekly", shown: false))
        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.session", in: "claude"))

        let relaunched = LayoutStore(registry: .mock, defaults: defaults)
        XCTAssertFalse(relaunched.isMetricShown("claude.weekly"))
        XCTAssertEqual(relaunched.orderedSupportedMetrics(for: "claude").map(\.id),
                       ["claude.today", "claude.session", "claude.weekly", "claude.extra"],
                       "the account page keeps listing a hidden metric in its place")
        XCTAssertEqual(relaunched.displayGroups.first { $0.provider.id == "claude" }?.metrics.map(\.id),
                       ["claude.today", "claude.session", "claude.extra"],
                       "All Usage, Priority and the menu bar all read these groups, so the hidden metric leaves each")
        XCTAssertTrue(relaunched.isMetricShown("codex.weekly"), "hiding is per account")

        XCTAssertTrue(relaunched.setMetric("claude.weekly", shown: true))
        XCTAssertTrue(LayoutStore(registry: .mock, defaults: defaults).isMetricShown("claude.weekly"))
    }

    func testTheAccountPageSwitchHidesItsMetric() async throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let id = store.add(kind: .claude, label: "Work", credential: .apiKey("key")).cardID
        try await waitUntil { container.layout.provider(id: id) != nil }
        let metrics = container.layout.orderedSupportedMetrics(for: id).map(\.id)

        let (_, host) = show(
            AccountDetailView(providerID: id, reorderSpaceName: "reorder", reorderLift: .constant(nil), frameStore: ReorderFrameStore())
                .frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
                .environment(container)
                .environment(container.layout)
                .environment(container.popover)
                .environment(container.dataStore)
        )
        let switches = Self.switches(in: host)
        XCTAssertEqual(switches.count, metrics.count, "every metric of the account has its own switch")
        switches[1].performClick(nil)

        try await waitUntil { !container.layout.isMetricShown(metrics[1]) }
        XCTAssertFalse(container.layout.visibleDescriptors.map(\.id).contains(metrics[1]))
        XCTAssertTrue(container.layout.isMetricShown(metrics[0]))
    }

    private static func switches(in view: NSView) -> [NSSwitch] {
        if let control = view as? NSSwitch { return [control] }
        return view.subviews.flatMap(switches(in:))
    }
}
