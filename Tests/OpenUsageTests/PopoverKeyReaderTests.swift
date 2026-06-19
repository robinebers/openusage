import XCTest
@testable import OpenUsage

/// `PopoverKeyReader.keyTargetsPopover` decides whether a bare Esc/Return keyDown should drive the
/// menu-bar popover: only when the event's key window IS the panel. The panel (a non-activating key
/// window) reliably takes key focus on show, so a foreign key window — a tracking menu, the About
/// panel — or no key window at all is left alone rather than hijacked.
final class PopoverKeyReaderTests: XCTestCase {
    /// Distinct instances stand in for windows; `ObjectIdentifier` gives each a stable identity.
    private final class WindowStub {}

    func testNilKeyWindowIsNotPopover() {
        // No key window is NOT the popover's: with the panel reliably key on show, a bare key with no
        // key window belongs to nothing we should act on (so an open menu / About panel keeps its key).
        let popover = WindowStub()
        XCTAssertFalse(
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
