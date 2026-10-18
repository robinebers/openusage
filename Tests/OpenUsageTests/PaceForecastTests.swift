import XCTest
@testable import OpenUsage

/// Locks seasonal-naive remaining (weekly) and elapsed-weighted blend (session) plus the
/// empirical-hit-rate red gate. Fixtures are quota-percent samples, not tokens.
final class PaceForecastTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let session: TimeInterval = 5 * 3600

    func testWeeklyAdaptiveBlend() {
        // Hand-checkable: remainders 20/30/40 → median 30; seasonal = 10 + 30 = 40.
        // linear = 10 / 0.4 = 25.
        // weight = 0.4^0.75 ≈ 0.50297.
        // projected = (1 - weight) * 40 + weight * 25 ≈ 32.46.
        let projected = Pace.projectUsage(used: 10, elapsed: week * 0.4, periodDuration: week,
                                          remainders: [20, 30, 40])
        XCTAssertEqual(projected, 32.46, accuracy: 0.02)
    }

    func testFewerThanTwoRemaindersReturnsLinear() {
        let elapsed = week * 0.5
        let linear = Pace.linearProjectedUsage(used: 30, elapsed: elapsed, periodDuration: week)
        XCTAssertEqual(linear, 60, accuracy: 0.01)
        XCTAssertEqual(
            Pace.projectUsage(used: 30, elapsed: elapsed, periodDuration: week, remainders: []),
            linear, accuracy: 0.01
        )
        XCTAssertEqual(
            Pace.projectUsage(used: 30, elapsed: elapsed, periodDuration: week, remainders: [10]),
            linear, accuracy: 0.01
        )
    }

    func testSessionBlendCloserToSeasonalWhenEarly() {
        let elapsed = session * 0.1
        let remainders = [10.0, 10.0, 10.0]
        let seasonal = 20.0 + 10.0
        let linear = Pace.linearProjectedUsage(used: 20, elapsed: elapsed, periodDuration: session)
        let blended = Pace.projectUsage(used: 20, elapsed: elapsed, periodDuration: session,
                                        remainders: remainders)
        XCTAssertGreaterThan(linear, seasonal)
        XCTAssertLessThan(abs(blended - seasonal), abs(blended - linear))
    }

    func testSessionBlendCloserToLinearWhenLate() {
        let elapsed = session * 0.9
        let remainders = [10.0, 10.0, 10.0]
        let seasonal = 20.0 + 10.0
        let linear = Pace.linearProjectedUsage(used: 20, elapsed: elapsed, periodDuration: session)
        let blended = Pace.projectUsage(used: 20, elapsed: elapsed, periodDuration: session,
                                        remainders: remainders)
        XCTAssertLessThan(abs(blended - linear), abs(blended - seasonal))
    }

    func testProjectedOverLimitStaysNonRedWhenHitRateBelowThreshold() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(week * 0.5) // 50% elapsed
        // used 80 + remainders 15/22/40 → median 22; linear = 160; blended ≈ 136.49 (over).
        // Hits: 95 no, 102 yes, 120 yes → 2/3 < 0.75, so onTrack not behind.
        let result = Pace.evaluate(used: 80, limit: 100, resetsAt: reset, periodDuration: week,
                                   now: now, remainders: [15, 22, 40])
        XCTAssertEqual(result?.status, .onTrack)
        XCTAssertEqual(result?.projectedUsage ?? 0, 136.49, accuracy: 0.05)
    }

    func testProjectedOverLimitIsRedWhenHitRateIsHigh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(week * 0.5)
        let result = Pace.evaluate(used: 80, limit: 100, resetsAt: reset, periodDuration: week,
                                   now: now, remainders: [25, 30, 35])
        XCTAssertEqual(result?.status, .behind)
        XCTAssertEqual(result?.projectedUsage ?? 0, 139.73, accuracy: 0.05)
    }

    func testMeterUsesSeasonalProjectionOnceIdentifiable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var data = WidgetData(title: "Weekly", icon: .providerMark("claude"), kind: .percent,
                              used: 10, limit: 100)
        data.resetsAt = now.addingTimeInterval(week * 0.5)
        data.periodDurationMs = Int(week * 1000)
        data.paceRemainders = [20, 30, 40] // projected ≈ 28.11 → ahead
        guard case .healthy(let fraction) = data.meterState(now: now) else {
            return XCTFail("expected healthy from seasonal remaining")
        }
        XCTAssertEqual(fraction, 0.28, accuracy: 0.01)
    }

    func testSanitizationAgainstNaNAndInfinities() {
        // Must never produce NaN, infinity, or crash
        let nanProj = Pace.projectUsage(used: .nan, elapsed: 100, periodDuration: session, remainders: [10, 20])
        XCTAssertTrue(nanProj.isFinite)

        let infProj = Pace.projectUsage(used: 100, elapsed: .infinity, periodDuration: session, remainders: [10, 20])
        XCTAssertTrue(infProj.isFinite)

        let zeroPeriod = Pace.projectUsage(used: 100, elapsed: 100, periodDuration: 0, remainders: [10, 20])
        XCTAssertEqual(zeroPeriod, 100)

        let negUsed = Pace.projectUsage(used: -50, elapsed: 100, periodDuration: session, remainders: [10, 20])
        XCTAssertEqual(negUsed, 0)
    }

    func testRemaindersArrayWithNaNAndNegativesFiltered() {
        // Dirty remainders with NaN and negatives must be filtered out gracefully
        let dirtyRemainders = [Double.nan, -20.0, Double.infinity, 30.0, 30.0]
        let hitRate = Pace.empiricalHitRate(used: 50, limit: 100, remainders: dirtyRemainders)
        XCTAssertNotNil(hitRate) // clean remainders [30, 30] count is 2 >= 2
        XCTAssertEqual(hitRate, 0.0) // 50 + 30 = 80 < 100
    }

    func testClockSkewNegativeElapsed() {
        // Negative elapsed (NTP jump backwards) must safely return current used without division by zero
        let proj = Pace.projectUsage(used: 42, elapsed: -15, periodDuration: session, remainders: [10, 20])
        XCTAssertEqual(proj, 42)
    }

    func testExpensiveModelBurstDoesNotPanicWhenUnidentifiable() {
        // A user switching to Opus and burning 25% of their session limit in 15 minutes
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(session - (15 * 60)) // 15 mins into 5h session (5% elapsed)
        
        var data = WidgetData(title: "Session", icon: .providerMark("claude"), kind: .percent,
                              used: 25, limit: 100)
        data.resetsAt = reset
        data.periodDurationMs = Int(session * 1000)
        data.paceRemainders = [] // cold start with no history
        
        // 5% elapsed is under the 25% session identifiability threshold.
        // Even though linear extrapolation would project 25 / 0.05 = 500% (screaming red),
        // the meter state must fall back to a calm normal level bar, suppressing false red alert.
        let state = data.meterState(now: now)
        XCTAssertEqual(state, .level(.normal))
    }
}

