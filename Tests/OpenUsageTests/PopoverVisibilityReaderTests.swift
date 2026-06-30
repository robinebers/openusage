import XCTest
import AppKit
@testable import OpenUsage

/// Guards the first-show fix for the popover visibility signal that drives the transient-state reset (on
/// close) and the reopen height re-seed (on show).
@MainActor
final class PopoverVisibilityReaderTests: XCTestCase {
    /// Occlusion alone misses the very first show — a freshly-created panel's `occlusionState` already
    /// contains `.visible`, so the first `makeKeyAndOrderFront` posts no change, leaving that first open
    /// unreported until a close-and-reopen. Becoming key (every open fires it) is the safeguard, so both
    /// triggers must stay wired.
    func testVisibilityTriggersCoverTheFirstShow() {
        let triggers = PopoverVisibilityReader.visibilityTriggers
        XCTAssertTrue(triggers.contains(NSWindow.didChangeOcclusionStateNotification),
                      "occlusion handles close and Space switches")
        XCTAssertTrue(triggers.contains(NSWindow.didBecomeKeyNotification),
                      "becoming key catches the first show occlusion misses")
    }

    // MARK: - Delivery rule (suppress a `false` before any `true` — PR #784 right-click → Settings)

    func testSuppressesPreShowFalseBeforeAnyShow() {
        // The regression: the reader mounts into the not-yet-ordered-front panel and reports false. That
        // must NOT be delivered — delivering it runs resetTransientState and clobbers a Settings screen
        // openSettings pre-set before showing.
        XCTAssertFalse(PopoverVisibilityReader.shouldDeliver(false, lastVisible: nil))
    }

    func testDeliversFirstShow() {
        XCTAssertTrue(PopoverVisibilityReader.shouldDeliver(true, lastVisible: nil))
    }

    func testDeliversRealDismissalAfterAShow() {
        XCTAssertTrue(PopoverVisibilityReader.shouldDeliver(false, lastVisible: true))
    }

    func testDeliversReshow() {
        XCTAssertTrue(PopoverVisibilityReader.shouldDeliver(true, lastVisible: false))
    }

    func testDedupesUnchangedReports() {
        XCTAssertFalse(PopoverVisibilityReader.shouldDeliver(false, lastVisible: false))
        XCTAssertFalse(PopoverVisibilityReader.shouldDeliver(true, lastVisible: true))
    }

    func testTypicalSequenceDeliversOnlyShowAndRealDismissal() {
        // Walk the lifecycle through the same logic `report` uses: pre-show false (suppressed) → first
        // show (delivered) → close (delivered).
        var last: Bool?
        var delivered: [Bool] = []
        func report(_ visible: Bool) {
            if PopoverVisibilityReader.shouldDeliver(visible, lastVisible: last) { delivered.append(visible) }
            last = visible
        }
        report(false)   // reader mounts into the not-yet-shown panel
        report(true)    // makeKeyAndOrderFront
        report(false)   // orderOut
        XCTAssertEqual(delivered, [true, false], "only the real show and the real dismissal are delivered")
    }
}
