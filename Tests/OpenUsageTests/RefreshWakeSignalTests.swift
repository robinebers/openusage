import XCTest
@testable import OpenUsage

/// Covers the refresh loop's between-passes wait. The regression that motivates these tests: the loop
/// used to subscribe to the enablement-change notification only *inside* its wait, so a change posted
/// while a refresh pass was still running (first-run credential detection finishing, `NewProviderSeeder`,
/// the Reset All reseed) was silently dropped, and newly enabled providers sat dataless until the next
/// scheduled pass. `RefreshWakeSignal` subscribes in `init` and buffers, so a wake can never be lost.
@MainActor
final class RefreshWakeSignalTests: XCTestCase {
    private let wakeName = Notification.Name("RefreshWakeSignalTests.wake")

    func testWakePostedBeforeWaitBeginsIsNotLost() async {
        // The lost-wake bug: the notification fires while the loop is busy refreshing (nobody is
        // suspended in a wait yet). The signal must buffer it and return immediately — a regression
        // here would sleep out the full (long) timeout and trip the elapsed assertion.
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        center.post(name: wakeName, object: nil)

        let start = Date()
        await signal.waitForWake(timeout: 60)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5,
            "a wake posted before the wait began must be buffered, not lost"
        )
    }

    func testWakeWhileWaitingResumesBeforeTimeout() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        let start = Date()
        let wait = Task { await signal.waitForWake(timeout: 60) }
        // Let the wait suspend before posting, so this exercises the live-wake path (not the buffer).
        await Task.yield()
        center.post(name: wakeName, object: nil)

        await wait.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNoWakeFallsBackToTimeout() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        let start = Date()
        await signal.waitForWake(timeout: 0.1)
        // `Task.sleep` never fires early; returning proves the timer path works without any wake.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
    }

    func testWakeBurstCoalescesIntoASingleWake() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        for _ in 0..<3 {
            center.post(name: wakeName, object: nil)
        }

        // The burst collapses into one buffered wake: the first wait consumes it immediately...
        await signal.waitForWake(timeout: 60)

        // ...and the second finds nothing buffered, so it sleeps out its full timeout.
        let start = Date()
        await signal.waitForWake(timeout: 0.1)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), 0.09,
            "a burst of wakes must coalesce into one, not queue up extra refresh passes"
        )
    }
}
