import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ScreenSlideTests: QuietWindowTestCase {
    func testTheAccountsPageSlidesAwayWithTheDashboardAndIsGoneOnceSettled() async throws {
        let hosted = try await hostPopover()
        let panel = hosted.panel, host = hosted.host
        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .accounts }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(scrollViews(in: host).count, 1, "the pager hasn't collapsed to the Accounts page")
        XCTAssertEqual(panel.frame.height, 108, "Accounts doesn't rest at its list's height")
        let resting = panel.frame.height
        let top = panel.frame.maxY

        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .dashboard }
        var sampled = false
        for _ in 0..<120 where !sampled {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            let pages = scrollViews(in: host)
            guard pages.count == 2,
                  let accounts = pages.first(where: { $0.contentInsets.top > 0 }),
                  let dashboard = pages.first(where: { $0.contentInsets.top == 0 }) else { continue }
            let accountsFrame = host.convert(accounts.bounds, from: accounts)
            guard accountsFrame.minX > 40, panel.frame.height > resting + 5 else { continue }
            sampled = true
            XCTAssertLessThan(host.convert(dashboard.bounds, from: dashboard).minX, 0, "the dashboard isn't sliding in from the left")
            XCTAssertEqual(accountsFrame.maxY, host.bounds.height, accuracy: 0.5, "the Accounts page isn't pinned to the panel's top")
            XCTAssertEqual(accountsFrame.height, host.bounds.height, accuracy: 0.5, "the Accounts page isn't following the panel's height")
            XCTAssertEqual(accounts.contentInsets.top, 44, "the Accounts page lost its top bar mid-slide")
        }
        XCTAssertTrue(sampled, "the Accounts page never slid right while the panel grew")

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(scrollViews(in: host).count, 1, "the pager didn't collapse once the slide settled")
        XCTAssertEqual(panel.frame.height, 166, "the dashboard doesn't rest at its content's height")
        XCTAssertEqual(panel.frame.maxY, top, "the panel's top edge moved")
    }

    func testSettingsKeepsItsChromeWhileItSlidesAway() async throws {
        let hosted = try await hostPopover()
        let panel = hosted.panel, host = hosted.host
        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .settings }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertGreaterThan(panel.frame.height, 600, "Settings doesn't rest at its content's height")

        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .dashboard }
        var sampled = false
        for _ in 0..<120 where !sampled {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            guard let settings = scrollViews(in: host).first(where: { ($0.documentView?.frame.height ?? 0) > 400 }) else { continue }
            let frame = host.convert(settings.bounds, from: settings)
            guard frame.minX > 40, panel.frame.height < 500 else { continue }
            sampled = true
            XCTAssertEqual(settings.contentInsets.top, 44, "Settings lost its top bar mid-slide")
            XCTAssertGreaterThan(settings.contentInsets.bottom, 40, "Settings lost its footer mid-slide")
            XCTAssertEqual(frame.maxY, host.bounds.height, accuracy: 0.5, "Settings isn't pinned to the panel's top")
            XCTAssertLessThan(frame.minX, PanelMetrics.width, "Settings is sliding past the pager's slot")
        }
        XCTAssertTrue(sampled, "Settings never slid right while the panel shrank")

        try await Task.sleep(for: .seconds(1.5))
        let parked = try XCTUnwrap(scrollViews(in: host).first { ($0.documentView?.frame.height ?? 0) > 400 }, "Settings was torn down instead of parked")
        XCTAssertEqual(host.convert(parked.bounds, from: parked).minX, 2 * PanelMetrics.width)
        XCTAssertEqual(parked.contentInsets.top, 0, "parked Settings keeps a top bar")
        XCTAssertEqual(panel.frame.height, 166)
    }

    /// One Claude account of two rows on the dashboard, the panel following SwiftUI's height from its
    /// top edge as the controller's bridge does, capped at 800.
    private func hostPopover() async throws -> HostedPopover {
        let hosted = try await hostPopover(accounts: ["Personal"])
        let panel = hosted.panel
        MenuBarPopover.clampHeight = { min($0, 800) }
        MenuBarPopover.applyHeight = { [weak panel] raw in
            guard let panel else { return }
            let height = min(raw, 800)
            guard abs(panel.frame.height - height) > 1 else { return }
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setFrame(PanelGeometry.frame(topLeft: topLeft, width: PanelMetrics.width, height: height), display: false)
        }
        try await hosted.open()
        XCTAssertEqual(panel.frame.height, 166, "the dashboard didn't open at its content's height")
        return hosted
    }
}
