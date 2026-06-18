import XCTest
@testable import OpenUsage

/// `EscapeToCloseReader.escapeTargetsPopover` decides whether an Esc keyDown should dismiss the
/// menu-bar popover. The nil-window case guards the macOS 26+ regression where the popover is
/// visible but not key, so the keyDown carries no window and a strict identity check would have
/// silently dropped it ("sometimes Esc doesn't close").
final class EscapeToCloseReaderTests: XCTestCase {
    /// Distinct instances stand in for windows; `ObjectIdentifier` gives each a stable identity.
    private final class WindowStub {}

    func testNilKeyWindowTargetsPopover() {
        // No key window (the accessory-app activation race): Esc still belongs to the popover.
        let popover = WindowStub()
        XCTAssertTrue(
            EscapeToCloseReader.escapeTargetsPopover(
                eventWindowID: nil,
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }

    func testMatchingWindowTargetsPopover() {
        // The normal path: the popover is key, so the keyDown carries its window id.
        let popover = WindowStub()
        XCTAssertTrue(
            EscapeToCloseReader.escapeTargetsPopover(
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
            EscapeToCloseReader.escapeTargetsPopover(
                eventWindowID: ObjectIdentifier(other),
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }
}
