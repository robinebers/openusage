import XCTest
@testable import OpenUsage

final class PanelOutsideClickPolicyTests: XCTestCase {
    func testNormalOutsideClickDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init()))
    }

    func testEveryKeepOpenReasonKeepsPanelOpen() {
        let contexts: [PanelOutsideClickContext] = [
            .init(isMorphing: true),
            .init(hasAttachedSheet: true),
            .init(isOnStatusButton: true),
            .init(isPanelWindow: true),
            .init(isStatusItemWindow: true),
            .init(isInsidePanel: true),
            .init(isMorphing: true, isInsidePanel: true),
            .init(eventWindowTypeName: "NSMenuWindow"),
            .init(eventWindowTypeName: "_NSPopoverWindow"),
        ]

        for context in contexts {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(context))
        }
    }

    func testMenuAndPopoverWindowMatchesAreCaseInsensitive() {
        for windowType in ["myPOPOVERwindow", "privateMENUwindow"] {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: windowType)))
        }
    }

    func testUnrelatedWindowDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "NSWindow")))
    }

    // MARK: - Status-button hit test (issue #1008)

    /// A button frame a few points shorter than its menu bar, the way AppKit lays it out: the
    /// screen tops out at y=1000 but the 24pt button frame ends at y=996.
    private let buttonFrame = NSRect(x: 100, y: 972, width: 40, height: 24)
    private let screenTop: CGFloat = 1000

    func testClickAtTopOfScreenWithRealCapturedGeometryHits() {
        // Verbatim from the diagnostic log that pinned the bug down: point {4122.98, 1555},
        // buttonFrame {{4061, 1529}, {242.5, 22}}, screen {{1728, -65}, {2880, 1620}} (maxY 1555).
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 4122.98046875, y: 1555),
            buttonFrame: NSRect(x: 4061, y: 1529, width: 242.5, height: 22),
            screenTop: 1555
        ))
    }

    func testClickInsideStatusButtonHits() {
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickInsideStatusButtonHitsWithoutAScreen() {
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: buttonFrame.maxY), buttonFrame: buttonFrame, screenTop: nil
        ))
    }

    func testClicksOutsideButtonEdgesAndTopStripMiss() {
        for point in [
            NSPoint(x: 99, y: 984),
            NSPoint(x: 141, y: 984),
            NSPoint(x: 150, y: screenTop),
            NSPoint(x: 120, y: 971)
        ] {
            XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
                point, buttonFrame: buttonFrame, screenTop: screenTop
            ))
        }
    }

    func testEmptyButtonFrameNeverHits() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            .zero, buttonFrame: .zero, screenTop: nil
        ))
    }
}
