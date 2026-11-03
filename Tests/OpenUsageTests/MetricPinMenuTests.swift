import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class MetricPinMenuTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let layout: LayoutStore
        let frames: Frames
        let account: String
        let session: String
        let weekly: String
    }

    /// One Claude account with Session at 10% and Weekly used up.
    private func hostDashboard(tab: DashboardTab, pinning pinned: (Hosted) -> String? = { _ in nil }) throws -> Hosted {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let account = store.add(kind: .claude, label: "Personal", credential: .apiKey("key")).cardID
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        container.popover.dashboardTab = tab
        container.dataStore.snapshots[account] = ProviderSnapshot(
            providerID: account, displayName: "Claude", plan: "Max 20x",
            lines: [
                .progress(label: "Session", used: 10, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 100, limit: 100, format: .percent),
            ]
        )
        let metrics = try XCTUnwrap(container.layout.displayGroups.first { $0.id == account }).metrics
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
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))
        let hosted = Hosted(
            window: window, host: host, layout: container.layout, frames: frames, account: account,
            session: try XCTUnwrap(metrics.first { $0.title == "Session" }).id,
            weekly: try XCTUnwrap(metrics.first { $0.title == "Weekly" }).id
        )
        if let id = pinned(hosted) { XCTAssertTrue(container.layout.setMetric(id, pinned: true)) }
        return hosted
    }

    /// The titles of the menu a right-click at `point` opens, separators as "", after choosing `title` in it.
    private func contextMenu(at point: CGPoint, in hosted: Hosted, choosing title: String? = nil) -> [String] {
        nonisolated(unsafe) var titles: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let menu = object as? NSMenu else { return }
                titles = menu.items.map { $0.isSeparatorItem ? "" : $0.title }
                nonisolated(unsafe) let tracked = menu
                RunLoop.main.perform(inModes: [.eventTracking]) {
                    MainActor.assumeIsolated {
                        if let title, let index = titles.firstIndex(of: title) { tracked.performActionForItem(at: index) }
                        tracked.cancelTracking()
                    }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            hosted.window.sendEvent(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: point.x, y: hosted.host.bounds.height - point.y),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .rightMouseDown ? 1 : 0
            )!)
        }
        return titles
    }

    private let accountMenu = ["Refresh", "Rename", "Edit Account…", "", "Share Screenshot"]

    func testRightClickingAMetricOnACardPinsOrUnpinsItAndTheAccountNameHasNoPin() async throws {
        try QuietTestProcess.requireFocus()
        let hosted = try hostDashboard(tab: .allUsage)
        try await waitUntil { [hosted.account, hosted.session, hosted.weekly].allSatisfy { hosted.frames.byID[$0] != nil } }
        let session = try XCTUnwrap(hosted.frames.byID[hosted.session])
        let row = CGPoint(x: session.midX, y: session.midY)

        XCTAssertEqual(contextMenu(at: row, in: hosted, choosing: "Pin"), ["Pin", ""] + accountMenu)
        XCTAssertTrue(hosted.layout.isMetricPinned(hosted.session))
        XCTAssertFalse(hosted.layout.isMetricPinned(hosted.weekly))

        XCTAssertEqual(contextMenu(at: row, in: hosted, choosing: "Unpin"), ["Unpin", ""] + accountMenu)
        XCTAssertFalse(hosted.layout.isMetricPinned(hosted.session))
        XCTAssertTrue(hosted.layout.undo(), "⌘Z puts the pin back")
        XCTAssertTrue(hosted.layout.isMetricPinned(hosted.session))

        let account = try XCTUnwrap(hosted.frames.byID[hosted.account])
        let name = CGPoint(x: account.midX, y: (account.minY + session.minY) / 2)
        XCTAssertEqual(contextMenu(at: name, in: hosted), accountMenu, "the account's name has no metric to pin")
    }

    func testRightClickingAPinnedRowOnPriorityUnpinsItAndAnyOtherRowPinsIt() async throws {
        try QuietTestProcess.requireFocus()
        let hosted = try hostDashboard(tab: .priority) { $0.session }
        try await Task.sleep(for: .milliseconds(300))
        /// The menus down the middle of the tab, top to bottom, one per row.
        func menus() -> [(y: CGFloat, titles: [String])] {
            stride(from: CGFloat(40), to: hosted.host.bounds.height - 40, by: 8).reduce(into: []) { found, y in
                let titles = contextMenu(at: CGPoint(x: hosted.host.bounds.midX, y: y), in: hosted)
                if !titles.isEmpty, found.last?.titles != titles { found.append((y, titles)) }
            }
        }

        let rows = menus()
        XCTAssertEqual(rows.map(\.titles), [["Unpin"], ["Pin"]], "Pinned's Session, then Used Up's Weekly")
        guard rows.count == 2 else { return }

        XCTAssertEqual(contextMenu(at: CGPoint(x: hosted.host.bounds.midX, y: rows[1].y), in: hosted, choosing: "Pin"), ["Pin"])
        XCTAssertTrue(hosted.layout.isMetricPinned(hosted.weekly))
        XCTAssertEqual(contextMenu(at: CGPoint(x: hosted.host.bounds.midX, y: rows[0].y), in: hosted, choosing: "Unpin"), ["Unpin"])
        XCTAssertFalse(hosted.layout.isMetricPinned(hosted.session))
        XCTAssertTrue(hosted.layout.undo(), "⌘Z puts the pin back")
        XCTAssertTrue(hosted.layout.isMetricPinned(hosted.session))
    }
}
