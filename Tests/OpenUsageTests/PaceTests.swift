import XCTest
@testable import OpenUsage

/// Locks the burn-rate pacing: the three-state thresholds (blue ahead / amber cutting-it-close /
/// red behind), the amber-only projected-balance marker and "~N% spare" copy, the plain-language
/// tooltip, and the run-out projection. All cases pin `now` and derive `resetsAt` from a target
/// elapsed fraction so the math is deterministic.
final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    /// A reset date such that exactly `elapsed` of the window has gone by as of `now`.
    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    func testZeroUsageIsAhead() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.status(used: 0, limit: 100, resetsAt: reset, periodDuration: week, now: now), .ahead)
    }

    func testAtOrOverLimitIsBehind() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.status(used: 100, limit: 100, resetsAt: reset, periodDuration: week, now: now), .behind)
        XCTAssertEqual(Pace.status(used: 130, limit: 100, resetsAt: reset, periodDuration: week, now: now), .behind)
    }

    func testTooEarlyInWindowReturnsNil() {
        let reset = resetsAt(elapsed: 0.02, period: week) // < 5% elapsed → no signal yet
        XCTAssertNil(Pace.status(used: 5, limit: 100, resetsAt: reset, periodDuration: week, now: now))
    }

    func testAheadOnTrackBehindThresholds() {
        let reset = resetsAt(elapsed: 0.5, period: week) // half the window gone → projected = used * 2
        XCTAssertEqual(Pace.status(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now), .ahead)   // 60 ≤ 90
        XCTAssertEqual(Pace.status(used: 44, limit: 100, resetsAt: reset, periodDuration: week, now: now), .ahead)   // 88 ≤ 90
        XCTAssertEqual(Pace.status(used: 46, limit: 100, resetsAt: reset, periodDuration: week, now: now), .onTrack) // 92 in (90,100]
        XCTAssertEqual(Pace.status(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now), .onTrack) // 100 lands exactly on the limit
        XCTAssertEqual(Pace.status(used: 60, limit: 100, resetsAt: reset, periodDuration: week, now: now), .behind)  // 120 > 100
    }

    func testStatusTextIsThePlainLanguageVerdict() {
        XCTAssertEqual(Pace.Status.ahead.statusText, "Well within limit")
        XCTAssertEqual(Pace.Status.onTrack.statusText, "Close to limit")
        XCTAssertEqual(Pace.Status.behind.statusText, "Will reach limit")
    }

    func testEvaluateProjectsEndOfPeriodUsage() {
        let reset = resetsAt(elapsed: 0.5, period: week) // half elapsed → projected = used * 2
        let result = Pace.evaluate(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now)
        XCTAssertEqual(result?.status, .ahead)
        XCTAssertEqual(result?.projectedUsage ?? 0, 60, accuracy: 0.01)
    }

    func testWindowAlreadyResetReturnsNil() {
        let past = now.addingTimeInterval(-60) // reset already happened
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: past, periodDuration: week, now: now))
        // Exact-reset boundary: resetsAt == now is already reset, not a live window.
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: now, periodDuration: week, now: now))
    }

    // MARK: MeterState (the view-facing projection of the pace verdict)

    /// Half the window gone, `used` percent of 100 spent → projected = used * 2.
    private func weeklyData(used: Double, displayMode: WidgetDisplayMode = .used) -> WidgetData {
        var data = WidgetData(title: "Weekly", icon: .symbol("clock"), kind: .percent,
                              used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = resetsAt(elapsed: 0.5, period: week)
        data.periodDurationMs = Int(week * 1000)
        return data
    }

    /// The amber tick fraction, present only in the `closeToLimit` state.
    private func tick(_ data: WidgetData) -> Double? {
        if case .closeToLimit(_, let tick) = data.meterState(now: now) { return tick }
        return nil
    }

    /// The amber spare copy, present only in the `closeToLimit` state.
    private func spare(_ data: WidgetData) -> String? {
        if case .closeToLimit(let spare, _) = data.meterState(now: now) { return spare }
        return nil
    }

    func testAmberTickFencesTheSpareOffAtTheFillEdgeInBothDisplayModes() {
        // Amber (projected 92%, spare 8%): the tick pins the 8% spare sliver to the fill's edge,
        // never to a track end. Used view: fill edge at 0.46, tick just outside it at
        // 0.46 + 0.08 = 0.54. Left view: fill edge at 0.54, tick just inside it at
        // 0.54 − 0.08 = 0.46.
        XCTAssertEqual(tick(weeklyData(used: 46)) ?? 0, 0.54, accuracy: 0.001)
        XCTAssertEqual(tick(weeklyData(used: 46, displayMode: .remaining)) ?? 0, 0.46, accuracy: 0.001)
        // Blue (plenty to spare) and red (won't survive anyway) both hide the tick.
        XCTAssertNil(tick(weeklyData(used: 30)))
        XCTAssertNil(tick(weeklyData(used: 60)))
    }

    func testNoTickWithoutAResetWindow() {
        var data = WidgetData(title: "Credits", icon: .symbol("creditcard"), kind: .dollars,
                              used: 12, limit: 20)
        XCTAssertNil(tick(data))                         // no reset window at all
        data.resetsAt = now.addingTimeInterval(week)
        XCTAssertNil(tick(data))                         // reset date but unknown period
    }

    func testTooltipIsTheVerdictWithNoDetailClause() {
        XCTAssertEqual(weeklyData(used: 30).meterState(now: now).tooltip, "Well within limit") // projected 60%
        XCTAssertEqual(weeklyData(used: 46).meterState(now: now).tooltip, "Close to limit")    // projected 92%
        XCTAssertEqual(weeklyData(used: 60).meterState(now: now).tooltip, "Will reach limit")  // projected 120%
    }

    func testSpentReadsLimitReached() {
        // Genuinely over the limit, and a remainder that rounds to empty, are both `spent` — which
        // outranks whatever the burn-rate verdict would otherwise say.
        XCTAssertEqual(weeklyData(used: 100).meterState(now: now), .spent)
        XCTAssertEqual(weeklyData(used: 100).meterState(now: now).tooltip, "Limit reached")
        let nearlyEmpty = WidgetData(title: "Credits", icon: .symbol("creditcard"), kind: .dollars,
                                     used: 99.999, limit: 100)
        XCTAssertEqual(nearlyEmpty.meterState(now: now), .spent)
        // $1.00 left → no longer empty, and with no reset window there's no pace story to tell.
        let withHeadroom = WidgetData(title: "Credits", icon: .symbol("creditcard"), kind: .dollars,
                                      used: 99.0, limit: 100)
        XCTAssertNil(withHeadroom.meterState(now: now).tooltip)
    }

    func testSpareCopyOnlyWhenAmber() {
        XCTAssertEqual(spare(weeklyData(used: 46)), "~8% spare")
        XCTAssertNil(spare(weeklyData(used: 30)))  // blue → no copy
        XCTAssertNil(spare(weeklyData(used: 60)))  // red → flame instead
    }

    func testSpentOutranksCloseToLimitSoNoTickOrSpare() {
        // The regression this refactor locks in: at 99.6% used with 99.7% of the window elapsed the
        // pace verdict is `onTrack` (projected ~99.9%), but the balance rounds to empty. `spent`
        // wins, so there is no amber tick and no "~0% spare" copy riding on a red bar.
        var data = WidgetData(title: "Weekly", icon: .symbol("clock"), kind: .percent,
                              used: 99.6, limit: 100)
        data.resetsAt = resetsAt(elapsed: 0.997, period: week)
        data.periodDurationMs = Int(week * 1000)
        XCTAssertEqual(data.meterState(now: now), .spent)
        XCTAssertNil(tick(data))
        XCTAssertNil(spare(data))
    }

    func testProjectedToLandAtTheLimitPromotesToRed() {
        // #632: projected ~99.6% (used 49.8, half the window gone) leaves a cushion that rounds to
        // 0%. Rather than an amber "~0% spare" bar contradicting the headline's remaining %, the
        // meter promotes to the red run-out state with the flame alone — there's no run-out time
        // because the projection doesn't cross the limit before the reset.
        let data = weeklyData(used: 49.8)
        XCTAssertEqual(data.meterState(now: now), .runningOut(eta: nil))
        XCTAssertNil(tick(data))                                          // no amber tick on a red bar
        XCTAssertNil(spare(data))                                         // no "~0% spare" copy
        XCTAssertEqual(data.meterState(now: now).tooltip, "Will reach limit")
    }

    func testProjectedExactlyAtLimitIsRedNotAmber() {
        // The amber/red boundary: the burn-rate classification still calls projected-exactly-100%
        // `onTrack` (Pace layer unchanged), but its cushion is 0%, so the meter shows red.
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.status(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now), .onTrack)
        XCTAssertEqual(weeklyData(used: 50).meterState(now: now), .runningOut(eta: nil))
    }

    func testSmallButRealCushionStaysAmber() {
        // Just below the promotion threshold: projected 98% (used 49) is a real, visible 2% cushion,
        // so it stays amber with matching copy + tick. The amber/red cut is between spare 1% and 0%.
        XCTAssertEqual(spare(weeklyData(used: 49)), "~2% spare")
        XCTAssertNotNil(tick(weeklyData(used: 49)))
    }

    func testRunningOutCarriesAnEtaBeforeReset() {
        // Behind, with the projected run-out landing before the reset → `runningOut` with a time.
        guard case .runningOut(let eta) = weeklyData(used: 60).meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNotNil(eta)
    }

    func testRunsOutOnlyWhenBehindAndBeforeReset() {
        let reset = resetsAt(elapsed: 0.33, period: week)
        let eta = Pace.secondsToRunOut(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now)
        XCTAssertEqual(eta ?? 0, 0.33 * week, accuracy: week * 0.01) // projected exhaustion ≈ ⅓ of a week out
        XCTAssertNil(Pace.secondsToRunOut(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now)) // ahead → nil
    }
}
