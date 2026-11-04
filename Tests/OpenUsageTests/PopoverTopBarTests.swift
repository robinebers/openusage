import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PopoverTopBarTests: QuietWindowTestCase {
    /// Before macOS 26 the button is an AppKit `NSButton`: its cell tracks a mouse-down in a modal loop
    /// that a mouse-up sent after `sendEvent` returns never reaches, so there the test presses it with
    /// `performClick`.
    func testTheAddNewAccountButtonOpensAddAccount() async throws {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults
        )
        let popover = container.popover

        popover.screen = .accounts
        let view = DashboardView()
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(UpdaterController())
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
        XCTAssertNil(window.attachedSheet)

        let point = NSPoint(x: host.bounds.midX, y: PanelMetrics.margin + 14)
        if #available(macOS 26, *) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )!)
                try await Task.sleep(for: .milliseconds(50))
            }
        } else {
            let target = host.convert(point, from: nil)
            let button = try XCTUnwrap(
                hostedViews(in: host).compactMap { $0 as? NSButton }.first { host.convert($0.bounds, from: $0).contains(target) },
                "no button at the bottom of Accounts"
            )
            button.performClick(nil)
        }
        try await waitUntil { window.attachedSheet != nil }

        XCTAssertTrue(popover.isAddingAccount)
        let sheet = try XCTUnwrap(window.attachedSheet, "the button didn't present the Add Account sheet")
        XCTAssertFalse(QuietTestProcess.onAScreen(sheet), "the sheet shows on a screen")
    }

    private func hostedViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + hostedViews(in: $0) }
    }
}
