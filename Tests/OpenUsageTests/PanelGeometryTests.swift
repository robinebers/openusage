import AppKit
import XCTest
@testable import OpenUsage

final class PanelGeometryTests: XCTestCase {
    func testHorizontalPlacementStaysInsideVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 900)
        let left = PanelGeometry.clampedTopLeft(
            below: NSRect(x: -40, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )
        let right = PanelGeometry.clampedTopLeft(
            below: NSRect(x: 490, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )

        XCTAssertEqual(left.x, 8)
        XCTAssertEqual(right.x, 172)
        XCTAssertEqual(left.y, 846)
    }

    func testShortDisplayCapsTheHeightToTheRoomBelowTheAnchor() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 200)
        let maximum = PanelGeometry.maximumHeight(
            topLeft: NSPoint(x: 100, y: 190),
            visibleFrame: visible
        )

        XCTAssertEqual(maximum, 170)
    }

    func testFractionalAnchorAndHeightsKeepTopEdgeOnOneWholePoint() {
        let topLeft = NSPoint(x: 995, y: 949.5)

        let frames = (0...1610).map { step in
            PanelGeometry.frame(topLeft: topLeft, width: 320, height: 567 + CGFloat(step) / 10)
        }

        XCTAssertEqual(Set(frames.map(\.maxY)), [949])
        XCTAssertTrue(frames.allSatisfy { $0.minY == $0.minY.rounded() && $0.height == $0.height.rounded() })
    }

    func testAttachedSheetRaisesThePanelUntilItEnds() {
        XCTAssertEqual(PanelGeometry.height(content: 250, attachedSheet: nil), 250)
        XCTAssertEqual(PanelGeometry.height(content: 250, attachedSheet: 394), 394 + PanelGeometry.sheetMargin)
        XCTAssertEqual(PanelGeometry.height(content: 600, attachedSheet: 394), 600)
    }
}
