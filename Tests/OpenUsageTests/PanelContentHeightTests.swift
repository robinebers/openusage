import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The panel is exactly as tall as the screen it shows, capped at 85% of the display. The popover
/// follows the real `PanelHeightController`, anchored above every screen so the panel never shows on one.
@MainActor
final class PanelContentHeightTests: QuietWindowTestCase {
    func testAccountsRestsAtItsContentHeight() async throws {
        let hosted = try await openWithController(accounts: ["Personal", "Work", "Side"])
        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .accounts }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(hosted.panel.frame.height, try contentHeight(in: hosted.host), accuracy: 1, "Accounts doesn't rest at its list's height")
    }

    func testAnOverTallDashboardRestsAtTheCap() async throws {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let hosted = try await openWithController(accounts: (0...Int(visible.height / 80)).map { "Account \($0)" })
        let cap = floor(visible.height * 0.85)
        XCTAssertGreaterThan(try contentHeight(in: hosted.host), cap, "the dashboard isn't taller than the cap")
        XCTAssertEqual(hosted.panel.frame.height, cap, accuracy: 1, "an over-tall dashboard doesn't rest at the cap")
    }

    private func contentHeight(in host: NSView) throws -> CGFloat {
        host.layoutSubtreeIfNeeded()
        let pages = scrollViews(in: host)
        XCTAssertEqual(pages.count, 1, "the pager hasn't settled on one screen")
        let page = try XCTUnwrap(pages.first)
        let document = try XCTUnwrap(page.documentView).frame.height
        return (document + page.contentInsets.top + page.contentInsets.bottom).rounded()
    }

    private func openWithController(accounts: [String]) async throws -> HostedPopover {
        let hosted = try await hostPopover(accounts: accounts)
        let popover = hosted.popover
        let controller = PanelHeightController(panel: hosted.panel, defaults: hosted.defaults) { popover.screen }
        controller.installBridge()
        addTeardownBlock { withExtendedLifetime(controller) {} }
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let button = NSRect(x: visible.minX + 100, y: (NSScreen.screens.map(\.frame.maxY).max() ?? 0) + 3_000, width: 20, height: 20)
        controller.prepareForOpening(below: button)
        try await hosted.open()
        XCTAssertEqual(hosted.panel.frame.maxY, (button.minY - PanelGeometry.topGap).rounded(.down), "the panel isn't hanging from its anchor")
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(hosted.panel.frame) }, "the panel sits on a screen at \(hosted.panel.frame)")
        return hosted
    }
}
