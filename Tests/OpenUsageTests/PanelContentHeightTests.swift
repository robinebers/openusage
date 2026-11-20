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

    /// A tab switch resizes the panel in one step, like a native window. It used to spring the panel
    /// through every height in between for about 0.6 s.
    func testATabSwitchResizesThePanelInOneStep() async throws {
        let hosted = try await openWithController(accounts: ["Personal", "Work", "Team"])
        try await waitUntil(timeout: .seconds(10)) { hosted.dataStore.refreshingProviderIDs.isEmpty && self.fitsContent(hosted) }
        let from = hosted.popover.dashboardTab
        let to: DashboardTab = from == .priority ? .allUsage : .priority
        let start = hosted.panel.frame.height
        nonisolated(unsafe) var heights: [CGFloat] = []
        let panel = hosted.panel
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { _ in
            MainActor.assumeIsolated { heights.append(panel.frame.height) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let segmentWidth = (PanelMetrics.width - 2 * PanelMetrics.margin) / 2
        let index = CGFloat(DashboardTab.allCases.firstIndex(of: to) ?? 0)
        click(CGPoint(x: PanelMetrics.margin + segmentWidth * (index + 0.5), y: PanelMetrics.margin + 14), hosted.panel, hosted.host)
        try await waitUntil { hosted.popover.dashboardTab == to && abs(hosted.panel.frame.height - start) > 1 }
        try await Task.sleep(for: .milliseconds(700))
        try await waitUntil { self.fitsContent(hosted) }

        XCTAssertEqual(heights.count, 1, "the panel animated through \(heights)")
    }

    /// A screen switch slides at AppKit's 0.25 s pace and drops the outgoing screen when it ends. The
    /// old spring kept both screens up for about 0.6 s, with a wobble at the end.
    func testAScreenSlideEndsAtTheNavigationPace() async throws {
        let hosted = try await openWithController(accounts: ["Personal"])
        try await waitUntil { self.fitsContent(hosted) }

        let started = ContinuousClock.now
        hosted.popover.toggle(.accounts)
        try await waitUntil { scrollViews(in: hosted.host).count == 2 }
        try await waitUntil { scrollViews(in: hosted.host).count == 1 }

        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(550))
    }

    /// A page whose height changes during the slide, like the first report of every new page, which
    /// comes before its bars are laid out. The correction used to start a second animation, which
    /// added to the first and carried the panel past the page's height before it came back.
    func testAHeightCorrectedMidSlideNeverOvershoots() async throws {
        let hosted = try await openWithController(accounts: ["Personal", "Work"])
        try await waitUntil { self.fitsContent(hosted) }
        try await Task.sleep(for: .milliseconds(300))

        let start = hosted.panel.frame.height
        let log = HeightLog(hosted.panel)
        hosted.popover.toggle(.accounts)
        try await Task.sleep(for: .milliseconds(60))
        _ = hosted.accounts.add(kind: .claude, label: "Team", credential: .apiKey("key"))
        try await settle(hosted)

        assertNeverPasses(log.heights, from: start, to: hosted.panel.frame.height)
    }

    /// The panel takes its height in one step for 300 ms after it opens. A slide the user started in
    /// that window used to jump to each new height the page reported in one frame.
    func testASlideStartedRightAfterOpeningAnimates() async throws {
        let hosted = try await openWithController(accounts: ["Personal", "Work"])
        let opened = ContinuousClock.now
        try await waitUntil { abs(hosted.panel.frame.height - PanelHeightController.defaultHeight) > 1 }

        let start = hosted.panel.frame.height
        let log = HeightLog(hosted.panel)
        hosted.popover.toggle(.accounts)
        try await Task.sleep(for: .milliseconds(60))
        let corrected = log.heights.count
        _ = hosted.accounts.add(kind: .claude, label: "Team", credential: .apiKey("key"))
        XCTAssertLessThan(ContinuousClock.now - opened, .milliseconds(300))
        try await settle(hosted)

        XCTAssertGreaterThan(log.heights.count - corrected, 3, "the panel jumped: \(log.heights)")
        assertNeverPasses(log.heights, from: start, to: hosted.panel.frame.height)
    }

    /// Opening an account and going back change the panel's height in one motion. The list's footer
    /// used to shrink or grow over 250 ms while the page swapped at once, so the panel jumped and then
    /// glided back the other way.
    func testOpeningAnAccountNeverReversesDirection() async throws {
        let hosted = try await openWithController(accounts: ["Personal"])
        try await waitUntil { self.fitsContent(hosted) }
        hosted.popover.toggle(.accounts)
        try await settle(hosted)
        let page = try XCTUnwrap(scrollViews(in: hosted.host).first)
        let footer = page.contentInsets.bottom
        XCTAssertGreaterThan(footer, 0)
        let id = try XCTUnwrap(hosted.accounts.accounts.first).cardID

        let list = hosted.panel.frame.height
        var log = HeightLog(hosted.panel)
        hosted.popover.customizeProviderID = id
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(page.contentInsets.bottom, 0, "the footer's space is still animating away")
        try await settle(hosted)
        let account = hosted.panel.frame.height
        XCTAssertGreaterThan(abs(account - list), 20)
        assertMovesOnce(log.heights, from: list, to: account)

        log = HeightLog(hosted.panel)
        hosted.popover.back()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(page.contentInsets.bottom, footer, "the footer's space is still animating in")
        try await settle(hosted)
        XCTAssertEqual(hosted.panel.frame.height, list, accuracy: 1)
        assertMovesOnce(log.heights, from: account, to: hosted.panel.frame.height)
    }

    /// Waits out the slide or page push, then until the panel fits its page.
    private func settle(_ hosted: HostedPopover) async throws {
        try await Task.sleep(for: .milliseconds(400))
        try await waitUntil { scrollViews(in: hosted.host).count == 1 && self.fitsContent(hosted) }
    }

    /// The panel stays between where it started and where it ends.
    private func assertNeverPasses(_ heights: [CGFloat], from start: CGFloat, to end: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(heights.count, 0, "the panel never resized", file: file, line: line)
        XCTAssertEqual(heights.last ?? start, end, accuracy: 1, file: file, line: line)
        let range = (min(start, end) - 1)...(max(start, end) + 1)
        if let past = heights.first(where: { !range.contains($0) }) {
            XCTFail("the panel went to \(past), past \(end): \([start] + heights)", file: file, line: line)
        }
    }

    /// The panel heads straight for its end height: each step is toward it and none passes it.
    private func assertMovesOnce(_ heights: [CGFloat], from start: CGFloat, to end: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let path = [start] + heights
        let direction: CGFloat = end >= start ? 1 : -1
        XCTAssertGreaterThan(heights.count, 0, "the panel never resized", file: file, line: line)
        XCTAssertEqual(path.last ?? start, end, accuracy: 1, file: file, line: line)
        for (from, to) in zip(path, path.dropFirst()) where (to - from) * direction < -1 {
            XCTFail("the panel turned back from \(from) to \(to) on its way to \(end): \(path)", file: file, line: line)
            return
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
        let controller = PanelHeightController(
            panel: hosted.panel, defaults: hosted.defaults, currentScreen: { popover.screen }, currentTab: { .priority }
        )
        controller.installBridge()
        addTeardownBlock { withExtendedLifetime(controller) {} }
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let button = NSRect(x: visible.minX + 100, y: (NSScreen.screens.map(\.frame.maxY).max() ?? 0) + 3_000, width: 20, height: 20)
        // The closed popover draws first, as it does from launch, so the view sees the panel open.
        hosted.host.layoutSubtreeIfNeeded()
        controller.prepareForOpening(below: button, tab: .priority)
        hosted.open()
        XCTAssertEqual(hosted.panel.frame.maxY, (button.minY - PanelGeometry.topGap).rounded(.down))
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(hosted.panel.frame) })
        return hosted
    }
}

/// Every height the panel takes, in order, from when it is made.
@MainActor
private final class HeightLog {
    private(set) var heights: [CGFloat] = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(_ panel: NSWindow) {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.heights.append(panel.frame.height) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
