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

    func testMaximumHeightUsesAvailableRoomAndDisplayCap() {
        let visible = NSRect(x: 0, y: 0, width: 1200, height: 1000)

        XCTAssertEqual(
            PanelGeometry.maximumHeight(topLeft: NSPoint(x: 100, y: 900), visibleFrame: visible),
            850
        )
    }

    func testSideNotchPlacementOpensToLeftAndStaysOnScreen() {
        let visible = NSRect(x: -200, y: -100, width: 1200, height: 900)
        let topLeft = PanelGeometry.clampedTopLeft(
            leftOf: NSRect(x: 912, y: 270, width: 88, height: 439),
            width: 320,
            height: 520,
            visibleFrame: visible
        )

        XCTAssertEqual(topLeft.x, 588)
        XCTAssertEqual(topLeft.y, 749.5)
        let frame = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 520)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + PanelGeometry.screenMargin)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - PanelGeometry.screenMargin)
    }

    func testShortDisplayMayShrinkBelowNormalMinimum() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 200)
        let maximum = PanelGeometry.maximumHeight(
            topLeft: NSPoint(x: 100, y: 190),
            visibleFrame: visible
        )

        XCTAssertEqual(maximum, 170)
        XCTAssertEqual(PanelGeometry.clampedHeight(600, maximum: maximum), 170)
    }

    func testHeightClampsToNormalMinimumAndDisplayMaximum() {
        XCTAssertEqual(PanelGeometry.clampedHeight(50, maximum: 700), 200)
        XCTAssertEqual(PanelGeometry.clampedHeight(900, maximum: 700), 700)
        XCTAssertEqual(PanelGeometry.clampedHeight(520, maximum: 700), 520)
    }

    func testChangingHeightKeepsTopEdgeFixed() {
        let topLeft = NSPoint(x: 120, y: 800)
        let short = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 300)
        let tall = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 650)

        XCTAssertEqual(short.maxY, topLeft.y)
        XCTAssertEqual(tall.maxY, topLeft.y)
        XCTAssertEqual(short.minX, tall.minX)
        XCTAssertEqual(short.width, tall.width)
    }
}

final class SideNotchGeometryTests: XCTestCase {
    func testFrameStaysFlushWithRightEdgeAndCentersVertically() {
        let frame = SideNotchGeometry.frame(
            size: NSSize(width: 88, height: 439),
            screenFrame: NSRect(x: -1080, y: -581, width: 1080, height: 1920),
            visibleFrame: NSRect(x: -1080, y: -581, width: 1080, height: 1920)
        )

        XCTAssertEqual(frame.maxX, 0)
        XCTAssertEqual(frame.midY, 379.5)
        XCTAssertEqual(frame.size, NSSize(width: 88, height: 439))
    }

    func testFrameClampsAnOversizedNotchToFullScreenHeight() {
        let visible = NSRect(x: 0, y: 30, width: 800, height: 300)
        let frame = SideNotchGeometry.frame(
            size: NSSize(width: 335, height: 439),
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 330),
            visibleFrame: visible
        )

        XCTAssertEqual(frame, NSRect(x: 465, y: 0, width: 335, height: 330))
    }
}

@MainActor
final class SideNotchViewModelTests: XCTestCase {
    func testExpandedStripHeightTracksSubscriptionCountAndCapsAtPanelHeight() {
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 0), 154.4, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 1), 154.4, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 2), 236.8, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 3), 319.2, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 4), 401.6, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 6), 566.4, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.stripHeight(subscriptionCount: 12), 576, accuracy: 0.001)
    }

    func testDetailWidthIncludesTheCardPointerGapAndRail() {
        XCTAssertEqual(SideNotchLayout.detailCardWidth, 216, accuracy: 0.001)
        XCTAssertEqual(SideNotchLayout.detailWidth, 308, accuracy: 0.001)
    }

    func testProviderLookupUsesStableVerticalFramesAcrossPanelWidthChanges() {
        let model = SideNotchViewModel()
        model.providerFrames = [
            "codex": CGRect(x: 9, y: 19, width: 70, height: 73),
            "claude": CGRect(x: 9, y: 109, width: 70, height: 73),
        ]

        XCTAssertEqual(model.provider(atVerticalOffset: 54), "codex")
        XCTAssertEqual(model.provider(atVerticalOffset: 145), "claude")
        XCTAssertNil(model.provider(atVerticalOffset: 100))
    }
}
