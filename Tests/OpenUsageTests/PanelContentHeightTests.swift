import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PanelContentHeightTests: QuietWindowTestCase {
    func testThePanelFitsAccountsAndGrowsWithTheSlideBackToTheDashboard() async throws {
        let hosted = try await openWithController(accounts: ["Personal"])
        try await waitUntil { self.fitsContent(hosted) }
        let dashboard = try XCTUnwrap(scrollViews(in: hosted.host).first)
        let top = hosted.panel.frame.maxY

        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .accounts }
        try await waitUntil {
            self.fitsContent(hosted) && scrollViews(in: hosted.host).first !== dashboard
        }
        let accounts = try XCTUnwrap(scrollViews(in: hosted.host).first)
        let resting = hosted.panel.frame.height
        let barHeight = accounts.contentInsets.top
        XCTAssertGreaterThan(barHeight, 0)

        // The old pager dropped Accounts on the first frame. On macOS 15 it could also leave
        // the panel at the shorter Accounts height until the slide was over.
        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .dashboard }
        try await waitUntil {
            guard accounts.isDescendant(of: hosted.host) else { return false }
            let frame = hosted.host.convert(accounts.bounds, from: accounts)
            return frame.minX > 0 && frame.minX < hosted.host.bounds.width
                && accounts.contentInsets.top == barHeight
                && hosted.panel.frame.height > resting + 1
        }
        try await waitUntil { !accounts.isDescendant(of: hosted.host) && self.fitsContent(hosted) }
        XCTAssertEqual(hosted.panel.frame.maxY, top)
    }

    func testAnOverTallDashboardRestsAtTheCap() async throws {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let hosted = try await openWithController(accounts: (0...Int(visible.height / 80)).map { "Account \($0)" })
        let cap = floor(visible.height * 0.85)
        try await waitUntil {
            guard let height = self.contentHeight(hosted.host) else { return false }
            return height > cap && abs(hosted.panel.frame.height - cap) <= 1
        }
    }

    private func fitsContent(_ hosted: HostedPopover) -> Bool {
        guard let height = contentHeight(hosted.host) else { return false }
        return abs(hosted.panel.frame.height - height) <= 1
    }

    private func contentHeight(_ host: NSView) -> CGFloat? {
        let pages = scrollViews(in: host)
        guard pages.count == 1, let page = pages.first, let document = page.documentView else { return nil }
        return (document.frame.height + page.contentInsets.top + page.contentInsets.bottom).rounded()
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
        hosted.open()
        XCTAssertEqual(hosted.panel.frame.maxY, (button.minY - PanelGeometry.topGap).rounded(.down))
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(hosted.panel.frame) })
        return hosted
    }
}
