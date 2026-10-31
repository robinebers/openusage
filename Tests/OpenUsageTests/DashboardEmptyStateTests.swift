import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardEmptyStateTests: QuietWindowTestCase {
    func testHidingEveryMetricDoesNotAskForAnAccount() async throws {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults
        )
        let dashboard = show(
            DashboardContentView(reorderSpaceName: "reorder", reorderLift: .constant(nil), scrollPosition: .constant(ScrollPosition(edge: .top)))
                .environment(container)
                .environment(container.layout)
                .environment(container.popover)
                .environment(container.dataStore)
                .environment(container.renaming)
                .environment(UpdaterController())
                .environment(\.colorScheme, .light),
            in: .titled,
            size: CGSize(width: PanelMetrics.width, height: 300)
        ).host
        try await Task.sleep(for: .milliseconds(300))
        let addAnAccount = try pixels(of: dashboard)

        let account = container.accounts.add(kind: .claude, label: "Personal", credential: .apiKey("key"))
        try await Task.sleep(for: .milliseconds(300))
        for metric in container.layout.registry.descriptors(for: account.cardID) {
            container.layout.setMetricEnabled(metric.id, false)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(container.layout.displayGroups.count, 0)
        XCTAssertNotEqual(try pixels(of: dashboard), addAnAccount, "a signed-in user with every metric hidden sees Add an Account")
    }
}
