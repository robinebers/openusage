import AppKit
import XCTest
@testable import OpenUsage

final class PopoverKeyTests: XCTestCase {
    private func key(_ keyCode: UInt16, _ typed: String, _ flags: NSEvent.ModifierFlags = .command) throws -> PopoverKey? {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: keyCode
        ))
        return PopoverKey(event)
    }

    func testCommandShortcutsFollowTheTypedCharacterOnEveryLayout() throws {
        XCTAssertEqual(try key(6, "z"), .undo, "QWERTY ⌘Z")
        XCTAssertEqual(try key(43, ","), .settings, "QWERTY ⌘,")
        XCTAssertEqual(try key(16, "z"), .undo, "QWERTZ ⌘Z, where QWERTY has Y")
        XCTAssertNil(try key(6, "y"), "QWERTZ ⌘Y")
        XCTAssertEqual(try key(13, "z"), .undo, "AZERTY ⌘Z, where QWERTY has W")
        XCTAssertNil(try key(6, "w"), "AZERTY ⌘W")
        XCTAssertEqual(try key(46, ","), .settings, "AZERTY ⌘, where QWERTY has M")
        XCTAssertNil(try key(43, ";"), "AZERTY ⌘;")
        XCTAssertEqual(try key(44, "z"), .undo, "Dvorak ⌘Z")
        XCTAssertEqual(try key(13, ","), .settings, "Dvorak ⌘,")
    }

    func testEscAndReturnStayOnTheirKeys() throws {
        XCTAssertEqual(try key(53, "\u{1b}", []), .escape)
        XCTAssertEqual(try key(36, "\r", []), .return)
        XCTAssertNil(try key(36, "\r"), "⌘Return")
        XCTAssertNil(try key(6, "z", [.command, .shift]), "⇧⌘Z")
    }
}
