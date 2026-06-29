import XCTest
import AppKit
@testable import OpenUsage

/// Guards the first-show fix for the popover visibility signal that drives `\.popoverIsVisible` (which
/// pauses the easter-egg animation loops while the popover is hidden).
@MainActor
final class PopoverVisibilityReaderTests: XCTestCase {
    /// Occlusion alone misses the very first show — a freshly-created panel's `occlusionState` already
    /// contains `.visible`, so the first `makeKeyAndOrderFront` posts no change, leaving the egg frozen on
    /// first activation until a close-and-reopen. Becoming key (every open fires it) is the safeguard, so
    /// both triggers must stay wired.
    func testVisibilityTriggersCoverTheFirstShow() {
        let triggers = PopoverVisibilityReader.visibilityTriggers
        XCTAssertTrue(triggers.contains(NSWindow.didChangeOcclusionStateNotification),
                      "occlusion handles close and Space switches")
        XCTAssertTrue(triggers.contains(NSWindow.didBecomeKeyNotification),
                      "becoming key catches the first show occlusion misses")
    }
}
