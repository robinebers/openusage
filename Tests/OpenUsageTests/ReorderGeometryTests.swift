import CoreGraphics
import XCTest
@testable import OpenUsage

final class ReorderGeometryTests: XCTestCase {
    func testRegularRowsKeepCrossingThreshold() {
        let frames = [
            "dragged": CGRect(x: 0, y: 0, width: 100, height: 40),
            "target": CGRect(x: 0, y: 40, width: 100, height: 40)
        ]

        XCTAssertNil(reorderTarget(
            at: CGPoint(x: 20, y: 44),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["dragged", "target"]
        ))
        XCTAssertEqual(reorderTarget(
            at: CGPoint(x: 20, y: 48),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["dragged", "target"]
        ), "target")
    }

    func testDividerCanUseRegularRowThresholdWhenDraggingDown() {
        let frames = [
            "dragged": CGRect(x: 0, y: 0, width: 100, height: 40),
            "divider": CGRect(x: 0, y: 40, width: 100, height: 40)
        ]

        XCTAssertNil(reorderTarget(
            at: CGPoint(x: 20, y: 44),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["dragged", "divider"]
        ))
        XCTAssertEqual(reorderTarget(
            at: CGPoint(x: 20, y: 48),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["dragged", "divider"]
        ), "divider")
    }

    func testDividerCanUseRegularRowThresholdWhenDraggingUp() {
        let frames = [
            "above": CGRect(x: 0, y: 0, width: 100, height: 40),
            "divider": CGRect(x: 0, y: 40, width: 100, height: 40),
            "dragged": CGRect(x: 0, y: 80, width: 100, height: 40)
        ]

        XCTAssertNil(reorderTarget(
            at: CGPoint(x: 20, y: 76),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["above", "divider", "dragged"],
        ))
        XCTAssertEqual(reorderTarget(
            at: CGPoint(x: 20, y: 72),
            in: frames,
            excluding: "dragged",
            orderedIDs: ["above", "divider", "dragged"],
        ), "divider")
    }
}
