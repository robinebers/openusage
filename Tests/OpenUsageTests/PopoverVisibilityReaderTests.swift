import XCTest
import AppKit
@testable import OpenUsage

/// Guards the first-show fix for the popover visibility signal that drives `\.popoverIsVisible` (which
/// pauses the easter-egg animation loops while the popover is hidden).
@MainActor
final class PopoverVisibilityReaderTests: XCTestCase {
    /// Occlusion alone misses the very first show — a freshly-created panel's `occlusionState` already
    /// contains `.visible`, so the first `makeKeyAndOrderFront` posts no change, leaving the egg frozen on
    /// first activation until a close-and-reopen. Become-key (every open fires it) is that safeguard, and
    /// the become/resign-key pair tracks focus for the translucent keepalive (which runs only while
    /// unfocused). All three must stay wired.
    func testWindowStateTriggersCoverFirstShowAndFocus() {
        let triggers = PopoverVisibilityReader.windowStateTriggers
        XCTAssertTrue(triggers.contains(NSWindow.didChangeOcclusionStateNotification),
                      "occlusion handles close and Space switches")
        XCTAssertTrue(triggers.contains(NSWindow.didBecomeKeyNotification),
                      "becoming key catches the first show occlusion misses, and gains focus")
        XCTAssertTrue(triggers.contains(NSWindow.didResignKeyNotification),
                      "resigning key is when the keepalive must engage")
    }
}
