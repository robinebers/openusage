import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PopoverTopBarTests: QuietWindowTestCase {
    /// Before macOS 26 the + is an AppKit `NSButton`: its cell tracks a mouse-down in a modal loop that
    /// a mouse-up sent after `sendEvent` returns never reaches, so there the test presses it with
    /// `performClick`.
    func testTheAccountsBarsTrailingButtonOpensAddAccount() async throws {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults
        )
        let popover = container.popover

        let view = DashboardView()
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(UpdaterController())
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
        popover.screen = .accounts
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(window.attachedSheet)

        let point = NSPoint(x: host.bounds.width - PanelMetrics.margin - 14, y: host.bounds.height - 22)
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
                "no button under the +"
            )
            button.performClick(nil)
        }
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertTrue(popover.isAddingAccount)
        let sheet = try XCTUnwrap(window.attachedSheet, "the + didn't present the Add Account sheet")
        XCTAssertFalse(QuietTestProcess.onAScreen(sheet), "the sheet shows on a screen")
    }

    /// An account's page: Back leads the bar and the account's provider mark mirrors it on the trailing
    /// side, centred in the back button's footprint so the title stays centred. The mark is decoration:
    /// nothing in its slot is a control.
    ///
    /// Read from the layer tree rather than pixels: the bar is Liquid Glass, and the images inside a
    /// glass effect are composited by the window server, so an offscreen capture never shows them.
    func testTheAccountPagesBarMirrorsTheProviderMarkIntoTheBackButtonsFootprint() async throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let id = store.add(kind: .claude, label: "Personal", credential: .apiKey("key")).cardID
        for _ in 0..<200 where container.layout.displayGroups.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let popover = container.popover
        popover.screen = .accounts
        popover.customizeProviderID = id

        let height: CGFloat = 44
        let view = PopoverTopBar(screen: .accounts, height: height, horizontalPadding: PanelMetrics.margin)
            .frame(width: PanelMetrics.width)
            .environment(container)
            .environment(container.layout)
            .environment(popover)
            .environment(container.renaming)
        let host = show(view, in: .titled).host
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()

        let slot: CGFloat = 28
        let leading = CGRect(x: PanelMetrics.margin, y: (height - slot) / 2, width: slot, height: slot)
        let trailing = CGRect(x: PanelMetrics.width - PanelMetrics.margin - slot, y: leading.minY, width: slot, height: slot)
        let controls = hostedViews(in: host).map { host.convert($0.bounds, from: $0) }.filter { !$0.isEmpty && $0.width < PanelMetrics.width }
        XCTAssertTrue(controls.contains { $0 == leading }, "no Back button filling the leading slot: \(controls)")
        XCTAssertFalse(controls.contains { $0.intersects(trailing) }, "a control sits in the trailing slot: \(controls)")

        let drawn = drawnFrames(in: host)
        let marks = drawn.filter { trailing.contains($0) }
        XCTAssertEqual(marks.count, 1, "expected one provider mark in the trailing slot, got \(drawn)")
        let mark = try XCTUnwrap(marks.first)
        XCTAssertEqual(mark.midX, trailing.midX, accuracy: 0.5)
        XCTAssertEqual(mark.midY, trailing.midY, accuracy: 0.5)
        XCTAssertGreaterThan(mark.width, DashboardGrid.iconSize, "the mark isn't larger than the dashboard header's")
        XCTAssertLessThan(mark.width, slot, "the mark overruns the slot")
        let title = try XCTUnwrap(drawn.first { $0.minX > leading.maxX && $0.maxX < trailing.minX }, "no title between the slots: \(drawn)")
        XCTAssertEqual(title.midX, PanelMetrics.width / 2, accuracy: 1, "the title isn't centred")
    }

    /// Every AppKit view SwiftUI hosts under `view`: its own containers at the full width, and a focus
    /// ring, key-view proxy and tooltip anchor sized to each control.
    private func hostedViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + hostedViews(in: $0) }
    }

    private func drawnFrames(in host: NSView) -> [CGRect] {
        guard let root = host.layer else { return [] }
        func walk(_ layer: CALayer) -> [CGRect] {
            let own = layer.contents == nil ? [] : [layer.convert(layer.bounds, to: root)]
            return own + (layer.sublayers ?? []).flatMap(walk)
        }
        return walk(root)
    }

    func testLeavingAccountsDropsAnOpenAddAccountSheet() {
        let popover = PopoverState()
        popover.screen = .accounts
        popover.isAddingAccount = true

        popover.screen = .dashboard

        XCTAssertFalse(popover.isAddingAccount)
    }
}
