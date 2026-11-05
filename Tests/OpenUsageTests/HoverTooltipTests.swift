import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class HoverTooltipTests: QuietWindowTestCase {
    /// Hovers a view carrying `text` as its tooltip and returns the tooltip's frame once it shows. The tooltip
    /// panel is made transparent during its reveal delay, so it never shows on a screen.
    private func shownTooltip(_ text: String) async throws -> NSRect {
        let (window, host) = show(Color.clear.frame(width: 120, height: 40).hoverTooltip(text))
        defer {
            HoverTooltips.dismissAll()
            window.close()
        }
        let level = NSWindow.Level.popUpMenu.rawValue + 1
        func panel() -> NSWindow? { NSApp.windows.first { $0.level.rawValue == level } }
        try hover(CGPoint(x: 60, y: 20), window, host)
        try await waitUntil { panel() != nil }
        let tooltip = try XCTUnwrap(panel())
        XCTAssertFalse(tooltip.isVisible, "the tooltip waits before it shows")
        tooltip.alphaValue = 0
        try await waitUntil { tooltip.isVisible }
        return tooltip.frame
    }

    private func oneLineWidth(_ text: String) -> CGFloat {
        NSHostingView(rootView: Text(text).font(.system(size: 12)).fixedSize()).fittingSize.width
    }

    /// A tooltip keeps text that fits on one line, and wraps longer text onto lines of about equal width.
    func testATooltipStaysOnOneLineUntilItMustWrapThenBalancesItsLines() async throws {
        let short = "Alert when a limit requires your attention"
        let single = try await shownTooltip(short)
        XCTAssertLessThan(single.height, 30, "one line")
        XCTAssertEqual(single.width, oneLineWidth(short) + 16, accuracy: 2, "as wide as its text")

        let long = "OpenUsage intelligently displays the usage icons at risk of running out and that require your attention."
        let wrapped = try await shownTooltip(long)
        XCTAssertLessThanOrEqual(wrapped.width, 280)
        let lines = (oneLineWidth(long) / (280 - 16)).rounded(.up)
        XCTAssertGreaterThan(wrapped.height, 30, "wrapped")
        XCTAssertLessThan(wrapped.width - 16, oneLineWidth(long) / lines + 30, "each line is about an equal share")
    }
}
