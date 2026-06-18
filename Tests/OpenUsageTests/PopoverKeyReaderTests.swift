import XCTest
@testable import OpenUsage

/// `PopoverKeyReader.keyTargetsPopover` decides whether a bare Esc/Return keyDown should drive the
/// menu-bar popover. The nil-window case guards the macOS 26+ regression where the popover is
/// visible but not key, so the keyDown carries no window and a strict identity check would have
/// silently dropped it ("sometimes Esc doesn't close").
final class PopoverKeyReaderTests: XCTestCase {
    /// Distinct instances stand in for windows; `ObjectIdentifier` gives each a stable identity.
    private final class WindowStub {}

    func testNilKeyWindowTargetsPopover() {
        // No key window (the accessory-app activation race): the key still belongs to the popover.
        let popover = WindowStub()
        XCTAssertTrue(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: nil,
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }

    func testMatchingWindowTargetsPopover() {
        // The normal path: the popover is key, so the keyDown carries its window id.
        let popover = WindowStub()
        XCTAssertTrue(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: ObjectIdentifier(popover),
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }

    func testDifferentWindowDoesNotTargetPopover() {
        // A different non-nil window (e.g. an open NSMenu) owns the keyDown — leave it alone.
        let popover = WindowStub()
        let other = WindowStub()
        XCTAssertFalse(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: ObjectIdentifier(other),
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }
}
