import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarPanelTests: QuietWindowTestCase {
    func testTheHostingViewFillsTheContentViewAndIsNeverTheContentViewItself() {
        let panel = QuietMenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300))
        let hosting = NSHostingView(rootView: Color.clear)
        panel.host(hosting)
        XCTAssertFalse(panel.contentView === hosting)
        XCTAssertTrue(hosting.superview === panel.contentView)
        panel.setContentSize(NSSize(width: PanelMetrics.width, height: 500))
        XCTAssertEqual(hosting.frame, panel.contentView?.bounds)
    }
}
