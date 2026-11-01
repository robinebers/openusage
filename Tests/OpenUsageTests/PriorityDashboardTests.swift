import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PriorityDashboardTests: QuietWindowTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let boxWidth = PanelMetrics.width - 2 * PanelMetrics.margin

    private func account(_ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: personal, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: personal, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    private func limit(_ title: String, used: Double) -> WidgetData {
        var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(3600)
        return data
    }

    private func height(_ accounts: DashboardAccount...) throws -> Int {
        let board = PriorityBoard.make(accounts: accounts, now: now)
        return try InkMap(rendering: PriorityBoardList(board: board, now: now, onOpenAccount: { _ in }), width: boxWidth).height
    }

    func testAttentionRowsAre46PointsTallAndUsedUpRows28() throws {
        let oneAttention = try height(account(limit("A", used: 95)))
        let twoAttention = try height(account(limit("A", used: 95), limit("B", used: 90)))
        XCTAssertEqual(twoAttention - oneAttention, 46)

        let oneUsedUp = try height(account(limit("A", used: 100)))
        let twoUsedUp = try height(account(limit("A", used: 100), limit("B", used: 100)))
        XCTAssertEqual(twoUsedUp - oneUsedUp, 28)
    }

    func testAllClearStatesAreTheirOwnAndWaitingDoesNotClaimOne() throws {
        let waiting = try height(account())
        let allClear = try height(account(limit("Quiet", used: 10)))
        let usedUpAlone = try height(account(limit("Spent", used: 100)))
        let usedUpSection = try InkMap(rendering: Text("Used Up").font(.system(size: 11, weight: .semibold)).padding(.bottom, 2), width: boxWidth).height + 28

        XCTAssertEqual(waiting, 46, "waiting is one quiet row")
        XCTAssertGreaterThanOrEqual(allClear, 18 + 112 + 22, "the illustration, 18 pt above and 22 pt below")
        XCTAssertEqual(usedUpAlone, 46 + Int(PanelMetrics.margin) + usedUpSection,
                       "a used-up limit alone gets the compact All Clear row above Used Up")
    }

    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let defaults: UserDefaults
        let frames: Frames
        let accounts: [String]
    }

    /// The popover with accounts tall enough to scroll, where only the last one has a limit in trouble.
    private func hostDashboard(tab: DashboardTab) async throws -> Hosted {
        let defaults = isolatedDefaults()
        defaults.set(tab.rawValue, forKey: DashboardTab.key)
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let accounts = ["One", "Two", "Three", "Four", "Five", "Six"].map {
            store.add(kind: .claude, label: $0, credential: .apiKey("key")).cardID
        }
        for _ in 0..<400 where container.layout.displayGroups.count < accounts.count { try await Task.sleep(for: .milliseconds(5)) }
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
        try await Task.sleep(for: .milliseconds(300))
        return Hosted(window: window, host: host, defaults: defaults, frames: frames, accounts: accounts)
    }

    private func click(_ point: NSPoint, in window: NSWindow) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testClickingARowOpensAllMetricsScrolledToThatAccount() async throws {
        let hosted = try await hostDashboard(tab: .priority)
        let target = try XCTUnwrap(hosted.accounts.last)
        XCTAssertNil(hosted.frames.byID[target], "All Metrics isn't mounted on Priority")

        let firstRow = NSPoint(x: hosted.host.bounds.midX, y: hosted.host.bounds.height - 90)
        try await click(firstRow, in: hosted.window)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(hosted.defaults.string(forKey: DashboardTab.key), DashboardTab.allMetrics.rawValue, "the click didn't switch tabs")
        let frame = try XCTUnwrap(hosted.frames.byID[target], "the account never mounted")
        XCTAssertLessThan(frame.minY, hosted.host.bounds.height, "the account is still below the panel")
        XCTAssertLessThanOrEqual(frame.maxY, hosted.host.bounds.height + 1, "the account isn't in full view")
    }

    func testPickingATabGoesBackToTheTop() async throws {
        let hosted = try await hostDashboard(tab: .allMetrics)
        let first = try XCTUnwrap(hosted.accounts.first)
        let top = try XCTUnwrap(hosted.frames.byID[first]).minY
        let scroller = try XCTUnwrap(scrollViews(in: hosted.host).first)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroller.reflectScrolledClipView(scroller.contentView)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThan(try XCTUnwrap(hosted.frames.byID[first]).minY, top - 50, "the panel didn't scroll")

        hosted.defaults.set(DashboardTab.priority.rawValue, forKey: DashboardTab.key)
        try await Task.sleep(for: .milliseconds(200))
        hosted.defaults.set(DashboardTab.allMetrics.rawValue, forKey: DashboardTab.key)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(try XCTUnwrap(hosted.frames.byID[first]).minY, top, accuracy: 1)
    }

    func testNoAccountsAskForOneOnBothTabs() async throws {
        var pixels: [DashboardTab: Data] = [:]
        for tab in DashboardTab.allCases {
            let defaults = isolatedDefaults()
            defaults.set(tab.rawValue, forKey: DashboardTab.key)
            let registry = WidgetRegistry(providers: [], descriptors: [])
            let view = DashboardContentView(reorderSpaceName: "reorder", reorderLift: .constant(nil), scrollPosition: .constant(ScrollPosition(edge: .top)))
                .defaultAppStorage(defaults)
                .environment(LayoutStore(registry: registry, defaults: defaults))
                .environment(WidgetDataStore.forTesting([], registry: registry, defaults: defaults))
                .environment(PopoverState())
                .environment(UpdaterController())
                .environment(\.colorScheme, .light)
            let host = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300)).host
            try await Task.sleep(for: .milliseconds(300))
            pixels[tab] = try self.pixels(of: host)
        }
        XCTAssertEqual(pixels[.priority], pixels[.allMetrics])
    }

    func testThePickerOffersBothTabsAndDefaultsToPriority() {
        XCTAssertEqual(DashboardTab.allCases.map(\.label), ["Priority", "All Metrics"])
        XCTAssertEqual(isolatedDefaults().enumValue(forKey: DashboardTab.key, default: DashboardTab.priority), .priority)
    }
}
