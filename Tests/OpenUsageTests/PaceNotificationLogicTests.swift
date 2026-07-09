import XCTest
@testable import OpenUsage

private extension PaceNotificationToggles {
    static let allOn = PaceNotificationToggles(
        underTenPercent: true,
        healthyToClose: true,
        closeToRunningOut: true
    )
}

/// Covers the pure milestone logic that decides when a quota notification fires: worsening pace edges
/// (blue→yellow, yellow→red), the under-10%-remaining crossing, per-window dedup, reset rollover,
/// recovery re-arming, the no-trustworthy-pace suppression, and the toggle gates. Mirrors CodexBar's
/// QuotaWarningNotificationLogicTests.
final class PaceNotificationLogicTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_700_000_000)

    // Meter states with a comfortable fraction so the under-10% rule doesn't co-fire unless intended.
    private let healthy = WidgetData.MeterState.healthy(projectedFraction: 0.5)
    private let close = WidgetData.MeterState.closeToLimit(spare: "~5% spare", projectedFraction: 0.95)
    private let running = WidgetData.MeterState.runningOut(eta: nil, projectedFraction: 1.2)

    /// Run one evaluation from a prior state with all toggles on.
    private func step(
        _ state: WidgetData.MeterState,
        fraction: Double = 0.5,
        resetsAt: Date? = nil,
        from previous: NotificationState = NotificationState(),
        toggles: PaceNotificationToggles = .allOn
    ) -> PaceNotificationLogic.Transition {
        PaceNotificationLogic.transitions(
            state: state, fraction: fraction, resetsAt: resetsAt ?? reset,
            previous: previous, toggles: toggles
        )
    }

    // MARK: - Pace-verdict edges

    func testHealthyToCloseFiresOnce() {
        let first = step(healthy)
        XCTAssertTrue(first.fire.isEmpty)
        let second = step(close, from: first.newState)
        XCTAssertEqual(second.fire, [.healthyToClose])
    }

    func testStayingYellowDoesNotRefire() {
        var state = step(healthy).newState
        state = step(close, from: state).newState   // fires
        let again = step(close, from: state)        // still yellow
        XCTAssertTrue(again.fire.isEmpty)
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

    // MARK: - Under 10% remaining

    func testUnderTenPercentFiresOncePerWindow() {
        let primed = step(close, fraction: 0.50).newState   // prime at close, 50% remaining
        let first = step(close, fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let again = step(close, fraction: 0.05, from: first.newState)
        XCTAssertFalse(again.fire.contains(.underTenPercent))
    }

    // MARK: - Cold start with already-bad state

    func testColdStartPrimesWithoutFiring() {
        // First real observation at launch records the baseline without firing — an already-bad metric
        // shouldn't spam alerts the moment the app opens.
        let first = step(running, fraction: 0.02)
        XCTAssertTrue(first.fire.isEmpty, "cold start primes, it doesn't fire")
        // A later worsening (after recovery) still fires normally.
        let recovered = step(healthy, fraction: 0.50, from: first.newState).newState
        let red = step(running, fraction: 0.02, from: recovered)
        XCTAssertTrue(red.fire.contains(.closeToRunningOut))
        XCTAssertTrue(red.fire.contains(.underTenPercent))
    }

    // MARK: - Reset rollover

    func testResetRolloverClearsFiredSetSoItCanFireAgain() {
        var state = step(healthy).newState
        state = step(close, from: state).newState   // fires healthyToClose this window
        XCTAssertTrue(step(close, from: state).fire.isEmpty)   // deduped within the window
        // A later reset window: same worsening should fire again. Re-enter healthy then close in the
        // new window so the edge is present.
        let newReset = reset.addingTimeInterval(3600)
        let rolled = step(healthy, resetsAt: newReset, from: state).newState
        let refired = step(close, resetsAt: newReset, from: rolled)
        XCTAssertEqual(refired.fire, [.healthyToClose])
    }

    func testResetJitterDoesNotRearmRunningOutAlert() {
        var state = step(healthy).newState
        state = step(running, from: state).newState   // fires closeToRunningOut this window

        let jitteredReset = reset.addingTimeInterval(0.09)
        let stillRunningOut = step(running, resetsAt: jitteredReset, from: state)

        XCTAssertTrue(stillRunningOut.fire.isEmpty)
        XCTAssertEqual(stillRunningOut.newState.previousBucket, .runningOut)
        XCTAssertEqual(stillRunningOut.newState.resetsAt, jitteredReset)
    }

    func testResetJitterDoesNotRearmCloseAlert() {
        var state = step(healthy).newState
        state = step(close, from: state).newState   // fires healthyToClose this window

        let jitteredReset = reset.addingTimeInterval(0.09)
        let stillClose = step(close, resetsAt: jitteredReset, from: state)

        XCTAssertTrue(stillClose.fire.isEmpty)
        XCTAssertEqual(stillClose.newState.previousBucket, .close)
        XCTAssertEqual(stillClose.newState.resetsAt, jitteredReset)
    }

    // MARK: - Recovery re-arms

    func testRecoveryThenReworseningRefires() {
        var state = step(healthy).newState
        state = step(close, from: state).newState   // fired
        state = step(running, from: state).newState // fired closeToRunningOut
        // Recover all the way back to blue — clears the fired flags.
        state = step(healthy, from: state).newState
        // Worsen again: both edges should be available to fire once more.
        let close2 = step(close, from: state)
        XCTAssertEqual(close2.fire, [.healthyToClose])
        let red2 = step(running, from: close2.newState)
        XCTAssertEqual(red2.fire, [.closeToRunningOut])
    }

    func testUnderTenPercentReArmsAfterRecoveryAboveTen() {
        let primed = step(close, fraction: 0.50).newState   // prime at close, 50% remaining
        let first = step(close, fraction: 0.05, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let recovered = step(close, fraction: 0.50, from: first.newState)  // back above 10%
        XCTAssertFalse(recovered.fire.contains(.underTenPercent))
        let dipsAgain = step(close, fraction: 0.05, from: recovered.newState)
        XCTAssertTrue(dipsAgain.fire.contains(.underTenPercent))
    }

    // MARK: - No data / level-band states

    func testNoDataNeverFires() {
        let result = step(.noData, fraction: 0.01)
        XCTAssertTrue(result.fire.isEmpty)
    }

    func testLevelPrimesWithoutFiringOnFirstObservation() {
        // `.level` has used/limit data but no pace projection. The first observation primes (records the
        // under-10% baseline) without firing — like any other first observation.
        let result = step(.level(.critical), fraction: 0.01)
        XCTAssertTrue(result.fire.isEmpty)
    }

    func testLevelFiresAlmostOutUnderTenPercent() {
        // `.level` metrics still fire "Almost Out" on the under-10% edge — it's a remaining-based
        // trigger, not a pace one. No pace milestone fires for `.level`.
        let primed = step(.level(.critical), fraction: 0.20).newState
        let first = step(.level(.critical), fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        XCTAssertFalse(first.fire.contains(.healthyToClose))
        XCTAssertFalse(first.fire.contains(.closeToRunningOut))
    }

    func testUntrackedDoesNotDisturbPreviousSignals() {
        // healthy, then an untracked gap (e.g. a failed refresh → no data), then close. The gap must
        // not look like an improvement that re-arms, nor swallow the edge: close should still fire.
        var state = step(healthy).newState
        state = step(.noData, fraction: 0.5, from: state).newState
        let close = step(self.close, from: state)
        XCTAssertEqual(close.fire, [.healthyToClose])
    }

    // MARK: - Toggle gates

    func testMasterOffSuppressionIsCallerSide() {
        // The pure logic has no master flag; the caller gates it. With all per-triggers off, nothing
        // fires even on a clear worsening — this stands in for the per-trigger-off path.
        let off = PaceNotificationToggles(underTenPercent: false, healthyToClose: false, closeToRunningOut: false)
        let state = step(healthy, toggles: off).newState
        let close = step(self.close, fraction: 0.05, from: state, toggles: off)
        XCTAssertTrue(close.fire.isEmpty)
    }

    func testPerTriggerOffSuppressesOnlyThatMilestone() {
        // Only the yellow→red trigger is off; blue→yellow still fires.
        let toggles = PaceNotificationToggles(underTenPercent: false, healthyToClose: true, closeToRunningOut: false)
        let state = step(healthy, toggles: toggles).newState
        let close = step(self.close, fraction: 0.05, from: state, toggles: toggles)
        XCTAssertEqual(close.fire, [.healthyToClose])
        let red = step(running, fraction: 0.02, from: close.newState, toggles: toggles)
        XCTAssertTrue(red.fire.isEmpty)
    }

    func testOffToggleDoesNotConsumeTheEdge() {
        // A worsening while the trigger is off must not silently consume the crossing: previousBucket
        // stays behind, so turning the trigger back on while the quota is still in the worse bucket
        // fires on the next evaluation.
        let off = PaceNotificationToggles(underTenPercent: false, healthyToClose: false, closeToRunningOut: true)
        var state = step(healthy, toggles: off).newState   // prime at healthy
        let closeSkipped = step(self.close, fraction: 0.20, from: state, toggles: off)  // healthyToClose off
        XCTAssertTrue(closeSkipped.fire.isEmpty)
        state = closeSkipped.newState
        // Turn healthyToClose on; the metric is still close, so the next evaluation fires it.
        let on = PaceNotificationToggles(underTenPercent: false, healthyToClose: true, closeToRunningOut: true)
        let refired = step(self.close, fraction: 0.20, from: state, toggles: on)
        XCTAssertTrue(refired.fire.contains(.healthyToClose))
    }

    // MARK: - Fresh session window (treated as .level by the caller)

    func testFreshSessionLevelPrimesWithoutFiring() {
        // A fresh session window resolves to an absolute-level state (`.level`) with plenty of quota
        // left, so it primes without firing. (A `.level` metric can still fire "Almost Out" later if it
        // drops under 10% — see testLevelFiresAlmostOutUnderTenPercent.)
        let result = step(.level(.normal), fraction: 0.99)
        XCTAssertTrue(result.fire.isEmpty)
    }
}
