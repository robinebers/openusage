import XCTest
@testable import OpenUsage

/// Covers the meter fill's severity color, read off `MeterState.severity`. With a live reset window
/// the color is a pace verdict (blue ahead / yellow cutting-it-close / red projected to run out);
/// without one it falls back to the absolute level bands (yellow at 80% used, red at 10% left);
/// and a balance that rounds to empty is `spent` (red) ahead of either. It keys off the share
/// *used*, regardless of the Used/Left display mode.
final class MeterSeverityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func percentData(used: Double, limit: Double? = 100,
                             displayMode: WidgetDisplayMode = .used) -> WidgetData {
        WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent,
                   used: used, limit: limit, displayMode: displayMode)
    }

    /// `elapsed` of a week-long window gone as of `now`.
    private func pacedData(used: Double, elapsed: Double) -> WidgetData {
        var data = percentData(used: used)
        data.resetsAt = now.addingTimeInterval(week * (1 - elapsed))
        data.periodDurationMs = Int(week * 1000)
        return data
    }

    private func severity(_ data: WidgetData) -> WidgetData.MeterSeverity? {
        data.meterState(now: now).severity
    }

    // MARK: Pace-driven (a live reset window)

    func testBurningTooFastIsCriticalLongBeforeTheBarLooksFull() {
        // 66% used but only a third of the week gone → projected ~182% → red, despite the
        // absolute bands calling 66% "normal". This was the original complaint: a bar guaranteed
        // to run out days early stayed calm blue.
        XCTAssertEqual(severity(pacedData(used: 66, elapsed: 0.363)), .critical)
    }

    func testCoastingToTheResetStaysNormalEvenWhenNearlyDrained() {
        // 85% used with 96% of the window gone → projected ~89%, ≥10% to spare → blue, even
        // though the absolute bands would call 85% "warning".
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.96)), .normal)
    }

    func testProjectedIntoTheLastTenPercentIsWarning() {
        // 88% used with 90% of the window gone → projected ~97.8% → amber.
        XCTAssertEqual(severity(pacedData(used: 88, elapsed: 0.9)), .warning)
    }

    func testLimitReachedIsSpentRegardlessOfElapsed() {
        XCTAssertEqual(pacedData(used: 100, elapsed: 0.5).meterState(now: now), .spent)
        XCTAssertEqual(pacedData(used: 130, elapsed: 0.02).meterState(now: now), .spent)
    }

    func testRemainderRoundingToZeroIsSpentOverACalmerPace() {
        // 99.6% used with 99.7% of the window gone projects to ~99.9% → "Close to limit"/amber by
        // pace. But the 0.4% remaining rounds to "0% left", so the balance reads empty — spent
        // outranks the pace verdict, so the bar is red, not amber.
        XCTAssertEqual(pacedData(used: 99.6, elapsed: 0.997).meterState(now: now), .spent)
    }

    func testRemainderRoundingToZeroIsSpentWithoutAResetWindow() {
        // No reset/period → no pace signal, but a dollar metric one rounding-step from empty
        // ($0.004 of $100 left → "$0.00") still reads as spent.
        let dollars = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                 used: 99.996, limit: 100)
        XCTAssertEqual(dollars.meterState(now: now), .spent)
    }

    func testEarlyInWindowUsesPaceVerdictNotAbsoluteBands() {
        // Early in the window still projects pace — heavy usage at 2% elapsed is already behind.
        XCTAssertEqual(severity(pacedData(used: 50, elapsed: 0.02)), .critical)
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.02)), .critical)
    }

    // MARK: Absolute fallback (no reset window to project against)

    func testComfortableUsageIsNormal() {
        XCTAssertEqual(severity(percentData(used: 0)), .normal)
        XCTAssertEqual(severity(percentData(used: 50)), .normal)
        XCTAssertEqual(severity(percentData(used: 79)), .normal)
    }

    func testWarningStartsAtEightyPercentUsed() {
        XCTAssertEqual(severity(percentData(used: 80)), .warning)
        XCTAssertEqual(severity(percentData(used: 89)), .warning)
    }

    func testCriticalStartsAtTenPercentLeft() {
        XCTAssertEqual(severity(percentData(used: 90)), .critical)
        // Exactly at/over the limit is spent (still a red bar).
        XCTAssertEqual(percentData(used: 100).meterState(now: now), .spent)
        XCTAssertEqual(percentData(used: 130).meterState(now: now), .spent)
    }

    func testThresholdsUseTheHeadlinesWholePercentRounding() {
        // 79.6% reads "80% used" in the headline, so it must already be yellow; same at 89.6% → red.
        XCTAssertEqual(severity(percentData(used: 79.6)), .warning)
        XCTAssertEqual(severity(percentData(used: 89.4)), .warning)
        XCTAssertEqual(severity(percentData(used: 89.6)), .critical)
    }

    func testSeverityIgnoresTheUsedLeftDisplayMode() {
        // In Left mode the bar *fill* shows the remaining share, but the color still keys off usage.
        XCTAssertEqual(severity(percentData(used: 95, displayMode: .remaining)), .critical)
        XCTAssertEqual(severity(percentData(used: 85, displayMode: .remaining)), .warning)
        XCTAssertEqual(severity(percentData(used: 5, displayMode: .remaining)), .normal)
    }

    func testNonPercentKindsBandOnTheirShareOfTheLimit() {
        let dollars = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                 used: 45, limit: 50)
        XCTAssertEqual(severity(dollars), .critical) // $5 of $50 left = 10%

        let counts = WidgetData(title: "Requests", icon: .providerMark("codex"), kind: .count,
                                used: 400, limit: 500, countSuffix: "requests")
        XCTAssertEqual(severity(counts), .warning) // 80% used
    }

    func testUnboundedAndZeroLimitMetricsStayNormal() {
        XCTAssertEqual(severity(percentData(used: 99, limit: nil)), .normal)
        XCTAssertEqual(severity(percentData(used: 99, limit: 0)), .normal)
    }

    func testNoDataHasNoSeverity() {
        var data = percentData(used: 50)
        data.hasData = false
        XCTAssertEqual(data.meterState(now: now), .noData)
        XCTAssertNil(severity(data))
    }
}
