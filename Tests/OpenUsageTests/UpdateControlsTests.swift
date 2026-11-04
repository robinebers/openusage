import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The places 0.7.16 offered updates: the Options menu's Check for Updates…, the Settings Updates
/// section, and the dashboard's Update Available banner.
@MainActor
final class UpdateControlsTests: QuietWindowTestCase {
    /// Opens the real menu, which shows on a screen for one pass of its tracking loop.
    func testTheOptionsMenuChecksForUpdatesBetweenSettingsAndReportAnIssueWhileSparkleCan() async throws {
        try QuietTestProcess.requireFocus()
        let updater = UpdaterController()
        for canCheck in [false, true] {
            updater.canCheckForUpdates = canCheck
            let items = try await optionsMenuItems(updater: updater)
            XCTAssertEqual(items.map(\.title), [
                "Accounts", "Settings", "", "Check for Updates…", "", "Report an Issue…", "About OpenUsage", "Quit OpenUsage",
            ])
            XCTAssertEqual(items[3].isEnabled, canCheck, "Check for Updates… follows canCheckForUpdates (\(canCheck))")
        }
    }

    func testSettingsShowsTheUpdatesSectionAndDisablesItInADevBuild() async throws {
        for active in [false, true] {
            let switches = try await settingsSwitches(updaterActive: active)
            XCTAssertEqual(switches.count, 3, "Launch at Login, Check Automatically and Beta Updates (active: \(active))")
            XCTAssertEqual(switches.dropFirst().map(\.isEnabled), [active, active], "the update switches follow isActive")
        }
    }

    func testTheDashboardShowsTheBannerForAnAvailableUpdate() async throws {
        let without = try await dashboardHeight(availableUpdate: nil)
        let with = try await dashboardHeight(availableUpdate: "0.8.1")
        XCTAssertGreaterThan(with - without, 60, "the Update Available banner tops the dashboard")
    }

    /// Clicks the footer's round Options button and reads the menu AppKit tracks. The click blocks in the
    /// menu's tracking loop, so the menu closes itself on that loop's next pass.
    private func optionsMenuItems(updater: UpdaterController) async throws -> [NSMenuItem] {
        let container = testContainer()
        let footer = PopoverFooter(screen: .dashboard)
            .frame(width: PanelMetrics.width)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(updater)
        let (window, host) = show(footer)
        nonisolated(unsafe) var items: [NSMenuItem]?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let menu = object as? NSMenu, menu.items.contains(where: { $0.title == "Quit OpenUsage" }) else { return }
                items = menu.items
                nonisolated(unsafe) let tracked = menu
                RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                    MainActor.assumeIsolated { tracked.cancelTracking() }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await Task.sleep(for: .milliseconds(300))
        let button = NSPoint(x: host.bounds.maxX - PanelMetrics.margin - 4 - 13, y: PanelMetrics.margin + 13)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: button, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitUntil { items != nil }
        window.close()
        return try XCTUnwrap(items, "the Options button didn't open its menu")
    }

    /// The General tab's switches, in order.
    private func settingsSwitches(updaterActive: Bool) async throws -> [NSControl] {
        let container = testContainer()
        let updater = UpdaterController()
        updater.isActive = updaterActive
        container.popover.screen = .settings
        let settings = SettingsScreen()
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(updater)
        let (window, host) = show(settings, size: CGSize(width: PanelMetrics.width, height: 500))
        defer { window.close() }
        func controls(in view: NSView) -> [NSControl] {
            [view as? NSControl].compactMap { $0 } + view.subviews.flatMap(controls)
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return controls(in: host).contains { $0 is NSSwitch }
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return controls(in: host).filter { $0 is NSSwitch }
    }

    private func dashboardHeight(availableUpdate: String?) async throws -> CGFloat {
        let container = testContainer()
        let updater = UpdaterController()
        updater.availableUpdateVersion = availableUpdate
        let dashboard = DashboardView()
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(updater)
        return try await documentHeight(of: dashboard)
    }

    private func documentHeight(of view: some View) async throws -> CGFloat {
        let (window, host) = show(view, size: CGSize(width: PanelMetrics.width, height: 500))
        defer { window.close() }
        var height: CGFloat = 0
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            height = scrollViews(in: host).first?.documentView?.frame.height ?? 0
            return height > 0
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return scrollViews(in: host).first?.documentView?.frame.height ?? height
    }

    private func testContainer() -> AppContainer {
        let defaults = isolatedDefaults()
        return AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
    }
}
