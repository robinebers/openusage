import XCTest
@testable import OpenUsage

/// Locks the burn-rate pacing: the three-state thresholds (blue ahead / amber cutting-it-close /
/// red behind), the amber-only projected-balance marker and "~N% spare" copy, the numeric
/// projection-at-reset tooltip, and the run-out projection. All cases pin `now` and derive
/// `resetsAt` from a target elapsed fraction so the math is deterministic.
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
        if case .closeToLimit(_, let tick, _) = data.meterState(now: now) { return tick }
        return nil
    }

    /// The amber spare copy, present only in the `closeToLimit` state.
    private func spare(_ data: WidgetData) -> String? {
        if case .closeToLimit(let spare, _, _) = data.meterState(now: now) { return spare }
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

    func testTooltipShowsNumericProjectionAtReset() {
        // Each state surfaces the projected-at-reset figure the row doesn't already show: blue the
        // cushion, amber the usage (complementing the visible "~N% spare"), red the overage.
        XCTAssertEqual(weeklyData(used: 30).meterState(now: now).tooltip, "~40% left at reset")        // projected 60%
        XCTAssertEqual(weeklyData(used: 46).meterState(now: now).tooltip, "~92% used at reset")        // projected 92%
        XCTAssertEqual(weeklyData(used: 60).meterState(now: now).tooltip, "~20% over limit at reset")  // projected 120%
    }

    func testTooltipBlueCushionAtZeroUsage() {
        // Nothing spent → projected 0% → the full quota is the cushion.
        XCTAssertEqual(weeklyData(used: 0).meterState(now: now).tooltip, "~100% left at reset")
    }

    func testTooltipRedOverageFlooredToOnePercent() {
        // Projected 100.4% (used 50.2, half the window gone): a real overage that rounds to 0%, so
        // the copy floors to "~1%" rather than the nonsensical "~0% over limit".
        XCTAssertEqual(weeklyData(used: 50.2).meterState(now: now).tooltip, "~1% over limit at reset")
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
        guard case .runningOut(let eta, _) = data.meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNil(eta)                                                 // flame alone, no run-out time
        XCTAssertNil(tick(data))                                          // no amber tick on a red bar
        XCTAssertNil(spare(data))                                         // no "~0% spare" copy
        // Projected to land right at the limit, not past it → "used", not "over limit".
        XCTAssertEqual(data.meterState(now: now).tooltip, "~100% used at reset")
    }

    func testProjectedExactlyAtLimitIsRedNotAmber() {
        // The amber/red boundary: the burn-rate classification still calls projected-exactly-100%
        // `onTrack` (Pace layer unchanged), but its cushion is 0%, so the meter shows red.
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.status(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now), .onTrack)
        guard case .runningOut(let eta, _) = weeklyData(used: 50).meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNil(eta)
    }

    func testSmallButRealCushionStaysAmber() {
        // Just below the promotion threshold: projected 98% (used 49) is a real, visible 2% cushion,
        // so it stays amber with matching copy + tick. The amber/red cut is between spare 1% and 0%.
        XCTAssertEqual(spare(weeklyData(used: 49)), "~2% spare")
        XCTAssertNotNil(tick(weeklyData(used: 49)))
    }

    func testRunningOutCarriesAnEtaBeforeReset() {
        // Behind, with the projected run-out landing before the reset → `runningOut` with a time.
        guard case .runningOut(let eta, _) = weeklyData(used: 60).meterState(now: now) else {
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

    // MARK: Always Show Pacing (the opt-in even-pace tick + healthy copy)

    /// `used` percent of 100 with `elapsed` of the window gone (projected = used / elapsed),
    /// optionally opting into "always show pacing".
    private func pacedData(used: Double, elapsed: Double, displayMode: WidgetDisplayMode = .used,
                           alwaysShowPacing: Bool = false) -> WidgetData {
        var data = WidgetData(title: "Weekly", icon: .symbol("clock"), kind: .percent,
                              used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = resetsAt(elapsed: elapsed, period: week)
        data.periodDurationMs = Int(week * 1000)
        data.alwaysShowPacing = alwaysShowPacing
        return data
    }

    /// The even-pace tick fraction carried by the blue `healthy` bar (nil unless always-show is on).
    private func healthyTick(_ data: WidgetData) -> Double? {
        if case .healthy(_, let tick) = data.meterState(now: now) { return tick }
        return nil
    }

    func testHealthyBarHasNoTickByDefault() {
        // Off (default): the blue/healthy bar carries no even-pace tick (projected 75% → ahead).
        XCTAssertNil(healthyTick(pacedData(used: 30, elapsed: 0.4)))
    }

    func testAlwaysShowPacingAddsEvenPaceTickToHealthyBar() {
        // On: the blue bar gains the even-pace line — a steady user's fill edge (elapsed fraction =
        // used ÷ projected = 30/75 = 0.4). It's plotted in the bar's own coordinates (position from the
        // left = shown value ÷ limit), so it tracks the fill's framing. Used view plots the used share,
        // so the line is the elapsed fraction (0.4), landing in the gray just ahead of the small fill
        // (0.30) → "ahead". Left view plots the remaining share, so it mirrors to 1 − 0.4 = 0.6, landing
        // inside the large fill (0.70) just short of its edge → also "ahead".
        XCTAssertEqual(healthyTick(pacedData(used: 30, elapsed: 0.4, alwaysShowPacing: true)) ?? -1,
                       0.4, accuracy: 0.001)
        XCTAssertEqual(healthyTick(pacedData(used: 30, elapsed: 0.4, displayMode: .remaining,
                                             alwaysShowPacing: true)) ?? -1,
                       0.6, accuracy: 0.001)
    }

    func testEvenPaceNotchInLeftViewSitsInsideTheFill() {
        // Devin Weekly regression: a near-full Left bar early in its window. used 2 with ~30% of the
        // week gone → even-pace = 1 − 0.30 = 0.70, which sits inside the blue (the fill edge is 0.98);
        // the 0.70→0.98 gap is how far ahead you are. Always on the bar — no overshoot, no clamp.
        XCTAssertEqual(healthyTick(pacedData(used: 2, elapsed: 0.30, displayMode: .remaining,
                                             alwaysShowPacing: true)) ?? -1,
                       0.70, accuracy: 0.001)
    }

    func testAlwaysShowPacingSwitchesAmberTickToTheEvenPaceLine() {
        // Amber (used 46, half the window gone → projected 92%). Default tick is the slack edge
        // (0.46 + 0.08 spare = 0.54); with always-show on it becomes the even-pace line
        // (used ÷ projected = 46/92 = 0.5). The "~N% spare" copy is unaffected either way.
        XCTAssertEqual(tick(pacedData(used: 46, elapsed: 0.5)) ?? -1, 0.54, accuracy: 0.001)
        XCTAssertEqual(tick(pacedData(used: 46, elapsed: 0.5, alwaysShowPacing: true)) ?? -1,
                       0.5, accuracy: 0.001)
        XCTAssertEqual(spare(pacedData(used: 46, elapsed: 0.5, alwaysShowPacing: true)), "~8% spare")
    }

    func testAlwaysShowPacingAmberEvenPaceTickTracksTheFillFraming() {
        // Asymmetric elapsed so the even-pace line isn't its own mirror (which 0.5 is, hiding a swap).
        // used 76 with 80% of the window gone → projected 95 (onTrack, 5% spare); even-pace line =
        // used ÷ projected = 0.8. Used view plots used, so the tick is the elapsed fraction 0.8 (just
        // inside the slack edge at 0.76 + 0.05 = 0.81); Left view plots remaining, so it mirrors to
        // 1 − 0.8 = 0.2 (just inside the fill edge at 0.24).
        XCTAssertEqual(tick(pacedData(used: 76, elapsed: 0.8, alwaysShowPacing: true)) ?? -1,
                       0.8, accuracy: 0.001)
        XCTAssertEqual(tick(pacedData(used: 76, elapsed: 0.8, displayMode: .remaining,
                                      alwaysShowPacing: true)) ?? -1,
                       0.2, accuracy: 0.001)
    }

    func testAlwaysShowPacingNeverPutsATickOnARedBar() {
        // Behind (projected 120%) and spent both stay tick-free even with the setting on — the flame
        // and "Limit reached" / run-out time carry the message on a red bar, never a notch.
        XCTAssertNil(pacedData(used: 60, elapsed: 0.5, alwaysShowPacing: true).meterState(now: now).tick)
        XCTAssertNil(pacedData(used: 100, elapsed: 0.5, alwaysShowPacing: true).meterState(now: now).tick)
    }

    func testAlwaysShowPacingLeavesRowsWithoutPaceSignalPlain() {
        // No reset window → no pace signal → nothing to project, so no tick even with the setting on.
        var data = WidgetData(title: "Credits", icon: .symbol("creditcard"), kind: .dollars,
                              used: 12, limit: 20)
        data.alwaysShowPacing = true
        XCTAssertNil(data.meterState(now: now).tick)
        XCTAssertNil(data.meterState(now: now).tooltip)
    }
}
