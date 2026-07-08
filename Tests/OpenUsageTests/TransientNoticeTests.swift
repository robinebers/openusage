import XCTest
@testable import OpenUsage

/// Pins the timer semantics all three popover pills now share (pin-denial, share confirmation,
/// Customize notice): present bumps the replay trigger and re-arms the auto-clear; a re-present
/// cancels the earlier timer so the newer value gets its full stay; `clear()` resets immediately.
/// Margins are generous (sleeps only ever run long) to stay calm on a loaded CI machine.
@MainActor
final class TransientNoticeTests: XCTestCase {
    func testPresentBumpsTriggerAndAutoClears() async throws {
        let notice = TransientNotice<String?>(clearedValue: nil, timeout: .milliseconds(100))
        notice.present("Starred for menu bar")
        XCTAssertEqual(notice.value, "Starred for menu bar")
        XCTAssertEqual(notice.trigger, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(notice.value)
    }

    func testRePresentRestartsTheClearTimer() async throws {
        let notice = TransientNotice<String?>(clearedValue: nil, timeout: .milliseconds(800))
        notice.present("first")
        try await Task.sleep(for: .milliseconds(400))
        notice.present("second")
        // Nominal 1000ms: past the first present's 800ms deadline, well before the second's 1200ms.
        // If the first timer weren't cancelled, it would have wiped "second" here.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(notice.value, "second")
        XCTAssertEqual(notice.trigger, 2)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(notice.value)
    }

    func testClearResetsImmediatelyAndCancelsTheTimer() async throws {
        let notice = TransientNotice<Bool>(clearedValue: false, timeout: .milliseconds(100))
        notice.present(true)
        notice.clear()
        XCTAssertFalse(notice.value)
        // The trigger only moves on present — clear must not replay the pill.
        XCTAssertEqual(notice.trigger, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(notice.value)
    }
}
