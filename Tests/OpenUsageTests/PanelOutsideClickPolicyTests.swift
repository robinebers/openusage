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

    /// A menu-bar-height button frame whose top edge sits at the top of a pretend screen.
    private let buttonFrame = NSRect(x: 100, y: 976, width: 40, height: 24)

    func testClickAtTopOfScreenHitsStatusButton() {
        // With the cursor pinned to the top of the screen, `NSEvent.mouseLocation.y` reports exactly
        // the screen's — and the button frame's — maxY. `NSRect.contains` excludes max edges, which
        // made this dead-center click read as an outside click: the panel dismissed on mouse-down and
        // the button's mouse-up toggle reopened it, so the second click never closed the panel.
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: buttonFrame.maxY), buttonFrame: buttonFrame
        ))
    }

    func testClickInsideStatusButtonHits() {
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 988), buttonFrame: buttonFrame
        ))
    }

    func testClickBesideStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 99, y: 988), buttonFrame: buttonFrame
        ))
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 141, y: 988), buttonFrame: buttonFrame
        ))
    }

    func testClickBelowStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 975), buttonFrame: buttonFrame
        ))
    }

    func testEmptyButtonFrameNeverHits() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(.zero, buttonFrame: .zero))
    }
}
