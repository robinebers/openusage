import XCTest
@testable import OpenUsage

final class PaceNotificationLogicTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_700_000_000)

    private let healthy = WidgetData.MeterState.healthy
    private let close = WidgetData.MeterState.closeToLimit
    private let running = WidgetData.MeterState.runningOut

    private func step(
        _ state: WidgetData.MeterState,
        fraction: Double = 0.9,
        resetsAt: Date? = nil,
        from previous: NotificationState = NotificationState()
    ) -> PaceNotificationLogic.Transition {
        PaceNotificationLogic.transitions(
            state: state,
            severity: WidgetData(title: "Weekly", kind: .percent, used: (1 - fraction) * 100, limit: 100).severity,
            resetsAt: resetsAt ?? reset,
            previous: previous
        )
    }

    func testUnderThirtyPercentFiresOnce() {
        let first = step(healthy)
        XCTAssertTrue(first.fire.isEmpty)
        let second = step(healthy, fraction: 0.25, from: first.newState)
        XCTAssertEqual(second.fire, [.underThirtyPercent])
        XCTAssertTrue(step(healthy, fraction: 0.20, from: second.newState).fire.isEmpty)
    }

    func testTheLevelsTurnOverExactlyWhereTheBarsChangeColor() {
        let primed = step(healthy, fraction: 0.31).newState
        XCTAssertEqual(step(healthy, fraction: 0.30, from: primed).fire, [.underThirtyPercent])
        let orange = step(healthy, fraction: 0.11, from: primed).newState
        XCTAssertEqual(step(healthy, fraction: 0.10, from: orange).fire, [.underTenPercent])
    }

    func testDroppingStraightUnderTenOffersBothLevelsLowestFirst() {
        let primed = step(healthy).newState
        XCTAssertEqual(step(healthy, fraction: 0.05, from: primed).fire, [.underTenPercent, .underThirtyPercent])
    }

    func testCloseToRunningOutFires() {
        var state = step(healthy).newState
        state = step(close, from: state).newState
        let red = step(running, from: state)
        XCTAssertEqual(red.fire, [.closeToRunningOut])
    }

    func testJumpStraightFromHealthyToRedFiresCritical() {
        let state = step(healthy).newState
        let red = step(running, from: state)
        XCTAssertEqual(red.fire, [.closeToRunningOut])
    }

    func testUnderTenPercentFiresOncePerWindow() {
        let primed = step(close, fraction: 0.50).newState
        let first = step(close, fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let again = step(close, fraction: 0.05, from: first.newState)
        XCTAssertFalse(again.fire.contains(.underTenPercent))
    }

    func testColdStartPrimesWithoutFiring() {
        let first = step(running, fraction: 0.02)
        XCTAssertTrue(first.fire.isEmpty, "cold start primes, it doesn't fire")
        XCTAssertTrue(step(.unpaced, fraction: 0.01).fire.isEmpty)
        XCTAssertTrue(step(.unpaced, fraction: 0.99).fire.isEmpty)
        let recovered = step(healthy, fraction: 0.50, from: first.newState).newState
        let red = step(running, fraction: 0.02, from: recovered)
        XCTAssertTrue(red.fire.contains(.closeToRunningOut))
        XCTAssertTrue(red.fire.contains(.underTenPercent))
    }

    func testResetRolloverClearsFiredSetSoItCanFireAgain() {
        var state = step(healthy).newState
        state = step(running, from: state).newState
        XCTAssertTrue(step(running, from: state).fire.isEmpty)
        let newReset = reset.addingTimeInterval(3600)
        let rolled = step(healthy, resetsAt: newReset, from: state).newState
        let refired = step(running, resetsAt: newReset, from: rolled)
        XCTAssertEqual(refired.fire, [.closeToRunningOut])
    }

    func testResetJitterDoesNotRearmExistingAlerts() {
        let jitteredReset = reset.addingTimeInterval(0.09)
        for meterState in [close, running] {
            let primed = step(healthy).newState
            let fired = step(meterState, from: primed).newState
            XCTAssertTrue(step(meterState, resetsAt: jitteredReset, from: fired).fire.isEmpty)
        }
    }

    func testRecoveryThenReworseningRefires() {
        var state = step(healthy).newState
        state = step(healthy, fraction: 0.25, from: state).newState
        state = step(running, fraction: 0.25, from: state).newState
        state = step(healthy, from: state).newState
        let orange = step(healthy, fraction: 0.25, from: state)
        XCTAssertEqual(orange.fire, [.underThirtyPercent])
        let red2 = step(running, fraction: 0.25, from: orange.newState)
        XCTAssertEqual(red2.fire, [.closeToRunningOut])
    }

    func testUnderTenPercentReArmsAfterRecoveryAboveTen() {
        let primed = step(close, fraction: 0.50).newState
        let first = step(close, fraction: 0.05, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let recovered = step(close, fraction: 0.50, from: first.newState)
        XCTAssertFalse(recovered.fire.contains(.underTenPercent))
        let dipsAgain = step(close, fraction: 0.05, from: recovered.newState)
        XCTAssertTrue(dipsAgain.fire.contains(.underTenPercent))
    }

    func testNoDataNeverFires() {
        let result = step(.noData, fraction: 0.01)
        XCTAssertTrue(result.fire.isEmpty)
    }

    func testUnpacedLimitFiresOnlyAlmostOutUnderTenPercent() {
        let primed = step(.unpaced, fraction: 0.20).newState
        let first = step(.unpaced, fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        XCTAssertFalse(first.fire.contains(.underThirtyPercent))
        XCTAssertFalse(first.fire.contains(.closeToRunningOut))
    }

    func testUntrackedDoesNotDisturbPreviousSignals() {
        var state = step(healthy).newState
        state = step(.noData, fraction: 0.5, from: state).newState
        XCTAssertEqual(step(healthy, fraction: 0.25, from: state).fire, [.underThirtyPercent])
    }
}
