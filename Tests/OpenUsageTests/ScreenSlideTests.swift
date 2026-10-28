import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The screen slide as the panel hosts it: the outgoing and incoming screens move together, each
/// pinned to the top of the panel as its height morphs, and the outgoing one keeps its chrome until
/// the slide has settled; only then does the pager collapse to the destination.
@MainActor
final class ScreenSlideTests: QuietWindowTestCase {
    private struct Hosted {
        let panel: NSPanel
        let host: NSView
        let popover: PopoverState
    }

    /// Leaving Accounts for the dashboard: the Accounts page, top bar included, slides off to the
    /// right as the dashboard slides in from the left, both following the panel's shrinking height from
    /// the top, and the Accounts page is gone once the spring settles.
    func testTheAccountsPageSlidesAwayWithTheDashboardAndIsGoneOnceSettled() async throws {
        let hosted = try await hostPopover()
        let panel = hosted.panel, host = hosted.host
        withAnimation(Motion.modeSwitch) { hosted.popover.screen = .accounts }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(scrollViews(in: host).count, 1, "the pager hasn't collapsed to the Accounts page")
        XCTAssertEqual(panel.frame.height, 200, "Accounts doesn't rest at its floor")
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
            guard accountsFrame.minX > 40, panel.frame.height < 195 else { continue }
            sampled = true
            XCTAssertLessThan(host.convert(dashboard.bounds, from: dashboard).minX, 0, "the dashboard isn't sliding in from the left")
            XCTAssertEqual(accountsFrame.maxY, host.bounds.height, accuracy: 0.5, "the Accounts page isn't pinned to the panel's top")
            XCTAssertEqual(accountsFrame.height, host.bounds.height, accuracy: 0.5, "the Accounts page isn't following the panel's height")
            XCTAssertEqual(accounts.contentInsets.top, 44, "the Accounts page lost its top bar mid-slide")
        }
        XCTAssertTrue(sampled, "the Accounts page never slid right while the panel shrank")

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(scrollViews(in: host).count, 1, "the pager didn't collapse once the slide settled")
        XCTAssertEqual(panel.frame.height, 166, "the dashboard doesn't rest at its content's height")
        XCTAssertEqual(panel.frame.maxY, top, "the panel's top edge moved")
    }

    /// Leaving Settings for the dashboard: Settings keeps its bar and footer while it slides off to
    /// the right, pinned to the top of the shrinking panel; once settled it parks beyond the pager
    /// without chrome.
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

    private func scrollViews(in host: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// The popover as `StatusItemController` hosts it, with one Claude account of two rows, on its
    /// dashboard, the panel following SwiftUI's height from its top edge as the controller's bridge does.
    /// Motion is on whatever the Mac's Reduce Motion setting (the CI runner image turns it on), since
    /// the slide is what these tests watch.
    private func hostPopover() async throws -> Hosted {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let id = store.add(kind: .claude, label: "Personal", credential: .apiKey("key")).cardID
        for _ in 0..<400 where container.layout.displayGroups.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        container.dataStore.snapshots[id] = ProviderSnapshot(
            providerID: id, displayName: "Claude", plan: "Max 20x",
            lines: ["Session", "Weekly"].map {
                .progress(label: $0, used: 30, limit: 100, format: .percent, resetsAt: Date().addingTimeInterval(3600), periodDurationMs: 5 * 3_600_000)
            }
        )
        let layout = container.layout
        let hosting = NSHostingController(rootView: AnyView(
            DashboardView()
                .environment(\.reduceAnimations, false)
                .environment(container)
                .environment(layout)
                .environment(container.popover)
                .environment(container.dataStore)
                .environment(container.renaming)
                .environment(UpdaterController())
                .environment(\.colorScheme, .light)
        ))
        let panel = QuietMenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelHeightController.defaultHeight))
        panel.appearance = NSAppearance(named: .aqua)
        let host = hosting.view
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .duringViewResize
        panel.contentViewController = hosting

        let clamp: (CGFloat) -> CGFloat = { PanelGeometry.clampedHeight($0, minimum: PanelGeometry.minimumHeight(for: container.popover.screen), maximum: 800) }
        MenuBarPopover.clampHeight = clamp
        MenuBarPopover.applyHeight = { [weak panel] raw in
            guard let panel else { return }
            let height = clamp(raw)
            guard abs(panel.frame.height - height) > 1 else { return }
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setFrame(PanelGeometry.frame(topLeft: topLeft, width: PanelMetrics.width, height: height), display: false)
        }
        addTeardownBlock {
            MenuBarPopover.applyHeight = nil
            MenuBarPopover.clampHeight = nil
        }
        QuietTestProcess.show(panel, in: self)
        container.popover.popoverShown = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(panel.frame.height, 166, "the dashboard didn't open at its content's height")
        return Hosted(panel: panel, host: host, popover: container.popover)
    }
}
