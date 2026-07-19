import XCTest
@testable import OpenUsage

/// Fixtures are real measurements from a notched 14" MacBook Pro (logical 1800×1169, notch
/// x 791–1012) where the status item sat fully behind the notch while the log kept reporting
/// "Status item ready" — the app looked like it never launched.
final class NotchGeometryTests: XCTestCase {
    // Measured auxiliary areas: left 0–791, right 1012–1800, menu-bar strip y 1131–1169.
    private let auxLeft = NSRect(x: 0, y: 1131, width: 791, height: 38)
    private let auxRight = NSRect(x: 1012, y: 1131, width: 788, height: 38)
    private let screenFrame = NSRect(x: 0, y: 0, width: 1800, height: 1169)

    private var notch: NSRect {
        NotchGeometry.notchRect(
            auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight, screenFrame: screenFrame
        )!
    }

    func testNotchRectSpansTheGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(notch, NSRect(x: 791, y: 1131, width: 221, height: 38))
    }

    func testAdjacentAuxiliaryAreasMeanNoNotch() {
        let right = NSRect(x: 791, y: 1131, width: 1009, height: 38)
        XCTAssertNil(NotchGeometry.notchRect(
            auxiliaryTopLeft: auxLeft, auxiliaryTopRight: right, screenFrame: screenFrame
        ))
    }

    func testBarsStyleItemFullyBehindNotchIsEffectivelyHidden() {
        // Measured: bars style rendered 36pt at x=902 — zero visible pixels.
        let occlusion = NotchGeometry.occlusion(
            of: NSRect(x: 902, y: 1138, width: 36, height: 24), notch: notch
        )
        XCTAssertEqual(occlusion?.hiddenFraction, 1)
        XCTAssertEqual(occlusion?.nearestVisibleEdge, .right)
        XCTAssertEqual(occlusion?.nearestVisibleEdgeX, 1012)
        XCTAssertEqual(occlusion?.isEffectivelyHidden, true)
    }

    func testTextStyleItemMostlyBehindNotchIsEffectivelyHidden() {
        // Measured: text strip rendered 170pt at x=767 — only a 24pt sliver peeked out on the left.
        let occlusion = NotchGeometry.occlusion(
            of: NSRect(x: 767, y: 1138, width: 170, height: 24), notch: notch
        )
        XCTAssertEqual(occlusion!.hiddenFraction, 146.0 / 170.0, accuracy: 0.001)
        XCTAssertEqual(occlusion?.nearestVisibleEdge, .left)
        XCTAssertEqual(occlusion?.nearestVisibleEdgeX, 791)
        XCTAssertEqual(occlusion?.isEffectivelyHidden, true)
    }

    func testMostlyVisibleItemIsNotEffectivelyHidden() {
        // Only its right quarter dips under the notch; the item is still findable and clickable.
        let occlusion = NotchGeometry.occlusion(
            of: NSRect(x: 700, y: 1138, width: 120, height: 24), notch: notch
        )
        XCTAssertEqual(occlusion!.hiddenFraction, 29.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(occlusion?.isEffectivelyHidden, false)
    }

    func testItemClearOfTheNotchHasNoOcclusion() {
        XCTAssertNil(NotchGeometry.occlusion(
            of: NSRect(x: 1100, y: 1138, width: 36, height: 24), notch: notch
        ))
    }

    func testPanelAnchorFallsBackToTheRightNotchEdge() {
        let occlusion = NotchGeometry.occlusion(
            of: NSRect(x: 902, y: 1138, width: 36, height: 24), notch: notch
        )!
        let anchor = NotchGeometry.panelAnchorRect(
            for: occlusion,
            buttonRect: NSRect(x: 902, y: 1138, width: 36, height: 24),
            panelWidth: 320
        )
        XCTAssertEqual(anchor.minX, 1012)
        XCTAssertEqual(anchor.minY, 1138)
    }

    func testFallbackIsGatedToMacOS26AndBelow() {
        // macOS 27 ("Golden Gate") folds overflowing items behind a chevron instead of parking
        // them under the notch, so the fallback must stay off there and on for 15–26.
        XCTAssertTrue(NotchGeometry.fallbackIsNeeded(onMacOSMajorVersion: 15))
        XCTAssertTrue(NotchGeometry.fallbackIsNeeded(onMacOSMajorVersion: 26))
        XCTAssertFalse(NotchGeometry.fallbackIsNeeded(onMacOSMajorVersion: 27))
        XCTAssertFalse(NotchGeometry.fallbackIsNeeded(onMacOSMajorVersion: 28))
    }

    func testPanelAnchorRightAlignsAtTheLeftNotchEdge() {
        let occlusion = NotchGeometry.occlusion(
            of: NSRect(x: 767, y: 1138, width: 170, height: 24), notch: notch
        )!
        let anchor = NotchGeometry.panelAnchorRect(
            for: occlusion,
            buttonRect: NSRect(x: 767, y: 1138, width: 170, height: 24),
            panelWidth: 320
        )
        // The panel's left edge lands so its right edge meets the notch's left edge (791 − 320).
        XCTAssertEqual(anchor.minX, 471)
    }
}
