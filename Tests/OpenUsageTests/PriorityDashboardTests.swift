import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PriorityDashboardTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let defaults: UserDefaults
        let popover: PopoverState
        let frames: Frames
        let accounts: [String]
    }

    /// The popover with accounts tall enough to scroll, where only the last one has a limit in trouble.
    private func hostDashboard(tab: DashboardTab) -> Hosted {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let accounts = ["One", "Two", "Three", "Four", "Five", "Six"].map {
            store.add(kind: .claude, label: $0, credential: .apiKey("key")).cardID
        }
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        container.popover.dashboardTab = tab
        for id in accounts {
            container.dataStore.snapshots[id] = ProviderSnapshot(
                providerID: id, displayName: "Claude", plan: "Max 20x",
                lines: ["Session", "Weekly"].map {
                    .progress(label: $0, used: id == accounts.last ? 95 : 10, limit: 100, format: .percent)
                }
            )
        }
        let frames = Frames()
        let view = DashboardView()
            .defaultAppStorage(defaults)
            .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.byID = $0 }
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(UpdaterController())
            .environment(\.colorScheme, .light)
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
        return Hosted(window: window, host: host, defaults: defaults, popover: container.popover, frames: frames, accounts: accounts)
    }

    func testClickingAnAmountFlipsItAndTheRowItselfDoesNothing() async throws {
        let hosted = hostDashboard(tab: .priority)
        click(CGPoint(x: hosted.host.bounds.midX, y: 90), hosted.window, hosted.host)
        XCTAssertEqual(hosted.popover.dashboardTab, .priority)
        XCTAssertNil(hosted.defaults.string(forKey: "meterStyle"))

        click(CGPoint(x: hosted.host.bounds.maxX - 40, y: 90), hosted.window, hosted.host)
        try await waitUntil { hosted.defaults.string(forKey: "meterStyle") == WidgetDisplayMode.used.rawValue }
    }

    func testPickingATabGoesBackToTheTop() async throws {
        let hosted = hostDashboard(tab: .allUsage)
        let first = try XCTUnwrap(hosted.accounts.first)
        try await waitUntil { hosted.frames.byID[first] != nil }
        let top = try XCTUnwrap(hosted.frames.byID[first]).minY
        let scroller = try XCTUnwrap(scrollViews(in: hosted.host).first)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroller.reflectScrolledClipView(scroller.contentView)
        try await waitUntil { hosted.frames.byID[first].map { $0.minY < top - 50 } == true }

        hosted.popover.dashboardTab = .priority
        try await waitUntil { hosted.frames.byID[first] == nil }
        hosted.popover.dashboardTab = .allUsage
        try await waitUntil { hosted.frames.byID[first].map { abs($0.minY - top) < 1 } == true }
    }

    func testFirstAccountCanBeAddedFromEitherEmptyTab() async throws {
        let defaults = isolatedDefaults()
        let registry = WidgetRegistry(providers: [], descriptors: [])
        for tab in DashboardTab.allCases {
            let popover = PopoverState()
            popover.dashboardTab = tab
            let view = DashboardContentView(reorderSpaceName: "reorder", reorderLift: .constant(nil), scrollPosition: .constant(ScrollPosition(edge: .top)))
                .environment(LayoutStore(registry: registry, defaults: defaults))
                .environment(popover)
                .environment(UpdaterController())
            let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
            if #available(macOS 26, *) {
                // The call to action is the last control, just above the empty view's bottom padding.
                let empty = EmptyDashboardView {}.frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
                let height = NSHostingView(rootView: empty).fittingSize.height
                click(CGPoint(x: host.bounds.midX, y: DashboardContentView.barGap + height - 26 - 14), window, host)
            } else {
                // An AppKit button tracks mouse-down in a modal loop on macOS 15.
                let button = try XCTUnwrap(firstButton(in: host))
                button.performClick(nil)
            }
            try await waitUntil { popover.isAddingAccount }
        }
    }

    private func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for child in view.subviews {
            if let button = firstButton(in: child) { return button }
        }
        return nil
    }
}
