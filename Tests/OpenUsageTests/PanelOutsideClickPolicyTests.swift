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
            .init(eventWindowTypeName: "NSMenuWindow"),
            .init(eventWindowTypeName: "_NSPopoverWindow"),
        ]

        for context in contexts {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(context))
        }
    }

    func testPopoverWindowMatchIsCaseInsensitive() {
        // A click inside a hover popover (its own `_NSPopoverWindow`, floating outside the panel frame)
        // must keep the panel open so interactive controls in it — the resets "Use" button — receive
        // the click instead of being dismissed as an outside click.
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "myPOPOVERwindow"))
        )
    }

    func testInsidePanelKeepsOpenWithoutAnEventWindow() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isInsidePanel: true)))
    }

    func testInsidePanelStillKeepsOpenWhenAnotherReasonAlsoApplies() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isMorphing: true, isInsidePanel: true)))
    }

    func testMenuWindowMatchIsCaseInsensitive() {
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "privateMENUwindow"))
        )
    }

    func testUnrelatedWindowDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "NSWindow")))
    }

    // MARK: - Status-button hit test (issue #1008)

    /// A button frame a few points shorter than its menu bar, the way AppKit lays it out: the
    /// screen tops out at y=1000 but the 24pt button frame ends at y=996.
    private let buttonFrame = NSRect(x: 100, y: 972, width: 40, height: 24)
    private let screenTop: CGFloat = 1000

    func testClickAtTopOfScreenHitsStatusButton() {
        // The issue #1008 geometry, live-captured: with the cursor pinned to the top of the screen,
        // `NSEvent.mouseLocation.y` reports exactly the screen's maxY — a few points *above* the
        // button frame's top, in the menu-bar strip macOS still routes to the button. Reading it as
        // an outside click dismissed the panel on mouse-down, and the button's mouse-up toggle
        // reopened it, so the second click never closed the panel.
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: screenTop), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

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

    func testClickBesideStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 99, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 141, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickInTopStripBesideStatusButtonMisses() {
        // The upward extension widens the hit zone only vertically — a top-edge click next to the
        // button (over a neighboring status item) must still dismiss.
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 150, y: screenTop), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickBelowStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 971), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testEmptyButtonFrameNeverHits() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            .zero, buttonFrame: .zero, screenTop: nil
        ))
    }
}
