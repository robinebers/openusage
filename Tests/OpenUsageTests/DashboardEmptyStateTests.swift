import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardEmptyStateTests: QuietWindowTestCase {
    func testHidingEveryMetricDoesNotAskForAnAccount() async throws {
        let layout = LayoutStore(registry: WidgetRegistry(providers: [], descriptors: []), defaults: isolatedDefaults())
        let dashboard = show(
            DashboardContentView(reorderSpaceName: "reorder", reorderLift: .constant(nil), scrollPosition: .constant(ScrollPosition(edge: .top)))
                .environment(layout)
                .environment(PopoverState())
                .environment(UpdaterController())
                .environment(\.colorScheme, .light),
            in: .titled,
            size: CGSize(width: PanelMetrics.width, height: 300)
        ).host
        try await Task.sleep(for: .milliseconds(300))
        let addAnAccount = try pixels(of: dashboard)

        layout.apply(registry: .mock)
        for metric in WidgetRegistry.mock.descriptors {
            layout.setMetricEnabled(metric.id, false)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(layout.displayGroups.count, 0)
        XCTAssertNotEqual(try pixels(of: dashboard), addAnAccount, "a signed-in user with every metric hidden sees Add an Account")
    }
}
