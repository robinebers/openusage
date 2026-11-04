import XCTest
@testable import OpenUsage

final class DashboardRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 24 * 3600

    private func paced(used: Double, elapsed: Double = 0.5, period: TimeInterval? = nil, title: String = "Weekly") -> WidgetData {
        let period = period ?? week
        var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
        data.displayMode = .remaining
        data.resetsAt = now.addingTimeInterval(period * (1 - elapsed))
        data.periodDurationMs = Int(period * 1000)
        return data
    }

    func testTheResetsFigureWarnsInTheColourOfTheResetThatExpiresNext() {
        var resets = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
        resets.values = [MetricValue(number: 2, kind: .count, label: "available")]
        resets.showsResetExpiries = true
        let day: TimeInterval = 24 * 3600
        let cases: [(expiries: [TimeInterval], severity: WidgetData.MeterSeverity)] = [
            ([], .normal),
            ([7 * day + 3600], .normal),
            ([7 * day, 20 * day], .warning),
            ([20 * day, 2 * day], .critical),
            ([-1 * day, 20 * day], .critical)
        ]
        for (expiries, severity) in cases {
            resets.expiriesAt = expiries.map { now.addingTimeInterval($0) }
            XCTAssertEqual(resets.dashboardRow(now: now).mark, .value("2 available", severity: severity), "\(expiries)")
        }
    }

    func testOnlyABoundedReadingFlipsBetweenUsedAndLeft() {
        XCTAssertTrue(paced(used: 30).hasMeterStyleToggle)
        var badge = paced(used: 30)
        badge.valueTextOverride = "Disabled"
        XCTAssertFalse(badge.hasMeterStyleToggle)
        var credits = WidgetData(title: "Credits", kind: .count, used: 452, limit: nil)
        credits.values = [MetricValue(number: 452, kind: .count, label: "credits")]
        XCTAssertFalse(credits.hasMeterStyleToggle)
        var empty = paced(used: 30)
        empty.hasData = false
        XCTAssertFalse(empty.hasMeterStyleToggle)
    }

    func testTheBarAndTheAmountCarryTheColour() {
        XCTAssertEqual(paced(used: 93, elapsed: 0.2).dashboardRow(now: now).mark, .bar(fill: 0.07, severity: .critical, value: "7%", reset: "5d 14h"))
        XCTAssertEqual(paced(used: 49).dashboardRow(now: now).mark, .bar(fill: 0.51, severity: .normal, value: "51%", reset: "3d 12h"))
        XCTAssertEqual(paced(used: 85, elapsed: 0.9).dashboardRow(now: now).mark, .bar(fill: 0.15, severity: .warning, value: "15%", reset: "16h 48m"))
    }

    func testAUsedUpLimitIsMarkedAndKeepsItsOrdinaryResetLine() {
        XCTAssertEqual(paced(used: 100).dashboardRow(now: now).mark, .bar(fill: 0, severity: .critical, value: "0%", reset: "3d 12h", isUsedUp: true))
        var used = paced(used: 100)
        used.displayMode = .used
        XCTAssertEqual(used.dashboardRow(now: now).mark, .bar(fill: 1, severity: .critical, value: "100%", reset: "3d 12h", isUsedUp: true))
    }

    func testDollarLimitShowsCentsOnBothSidesOfTheMeter() {
        var data = WidgetData(title: "Key Limit", kind: .dollars, used: 9.6, limit: 10)
        for (mode, expected) in [(WidgetDisplayMode.remaining, "$0.40"), (.used, "$9.60")] {
            data.displayMode = mode
            guard case .bar(_, _, let amount, _, _) = data.dashboardRow(now: now).mark else {
                return XCTFail("Expected a bounded dollar row")
            }
            XCTAssertEqual(amount, expected)
        }
    }

    func testTheAmountSaysWhichReadingItIs() {
        var dollars = WidgetData(title: "Credits", kind: .dollars, used: 184.72, limit: 500)
        dollars.displayMode = .remaining
        XCTAssertEqual(dollars.amountText, "$315.28 left")
        dollars.displayMode = .used
        XCTAssertEqual(dollars.amountText, "$184.72 used")
        var badge = paced(used: 30)
        badge.valueTextOverride = "Disabled"
        XCTAssertEqual(badge.amountText, "Disabled")
    }

    func testAValueRowsSecondFigureIsItsDetail() {
        var today = WidgetData(title: "Today", kind: .dollars, used: 0, limit: nil)
        today.values = [MetricValue(number: 12.5, kind: .dollars), MetricValue(number: 3_000, kind: .count, label: "tokens")]
        XCTAssertEqual(today.dashboardRow(now: now).mark, .value("$12.50", detail: "3K tokens"))
        XCTAssertEqual(today.unboundedDetail, "$12.50 · 3K tokens")
        today.values.append(MetricValue(number: 4, kind: .count, label: "turns"))
        XCTAssertEqual(today.dashboardRow(now: now).mark, .value("$12.50", detail: "3K tokens · 4 turns"))
    }

    func testAFreshSessionACapWithoutAResetAndABadgeLeaveTheResetEmpty() {
        var fresh = paced(used: 0, elapsed: 0.1, period: 5 * 3600, title: "Session")
        fresh.sessionStartSignal = .zeroUsage
        XCTAssertEqual(fresh.dashboardRow(now: now).mark, .bar(fill: 1, severity: .normal, value: "100%", reset: nil))

        let dollars = WidgetData(title: "On-demand", kind: .dollars, used: 12, limit: 20)
        XCTAssertEqual(dollars.dashboardRow(now: now).mark, .bar(fill: 0.6, severity: .normal, value: "$12", reset: nil))

        var badge = WidgetData(title: "Status", kind: .count, used: 0, limit: nil)
        badge.valueTextOverride = "Disabled"
        XCTAssertEqual(badge.dashboardRow(now: now).mark, .value("Disabled"))
    }

    func testTheBarsHoverIsTheProjectionAtReset() {
        XCTAssertEqual(paced(used: 30).paceTooltip(now: now), "~40% left at reset")
        XCTAssertEqual(paced(used: 46).paceTooltip(now: now), "~92% used at reset")
        XCTAssertEqual(paced(used: 49.8).paceTooltip(now: now), "~100% used at reset")
        XCTAssertEqual(paced(used: 60).paceTooltip(now: now), "~20% over limit at reset")
        XCTAssertEqual(paced(used: 50.2).paceTooltip(now: now), "~1% over limit at reset")
        XCTAssertEqual(paced(used: 100).paceTooltip(now: now), "Limit reached")
        XCTAssertNil(paced(used: 4, elapsed: 0.02).paceTooltip(now: now), "a 4% reading early in the window is a level band, not a blow-out")
        XCTAssertNil(WidgetData(title: "Credits", kind: .dollars, used: 80, limit: 100).paceTooltip(now: now), "no window, no projection")
        var empty = paced(used: 30)
        empty.hasData = false
        XCTAssertNil(empty.paceTooltip(now: now))
    }

    func testTheValuesHoverIsTheOtherReadingAndTheResetsTheOtherFormat() {
        var data = paced(used: 30)
        XCTAssertEqual(data.meterStyleTooltip, "30% used", "the value reads 70%")
        data.displayMode = .used
        XCTAssertEqual(data.meterStyleTooltip, "70% left", "the value reads 30%")
        var badge = paced(used: 30)
        badge.valueTextOverride = "Disabled"
        XCTAssertNil(badge.meterStyleTooltip)
        var credits = WidgetData(title: "Credits", kind: .count, used: 452, limit: nil)
        credits.values = [MetricValue(number: 452, kind: .count, label: "credits")]
        XCTAssertNil(credits.meterStyleTooltip)

        XCTAssertEqual(data.resetTooltip(now: now), Formatters.compactClock(data.resetsAt!, now: now), "the reset reads 3d 12h")
        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.resetTooltip(now: now), "3d 12h")
        data.resetsAt = now.addingTimeInterval(-1)
        XCTAssertNil(data.resetTooltip(now: now), "a due reset reads soon either way")
        var fresh = paced(used: 0, elapsed: 0.1, period: 5 * 3600, title: "Session")
        fresh.sessionStartSignal = .zeroUsage
        XCTAssertNil(fresh.resetTooltip(now: now))
        XCTAssertNil(credits.resetTooltip(now: now))
    }

    func testOnlyAnEmptyBarFades() {
        let row = { (fill: Double, isUsedUp: Bool) in
            DashboardRowModel(label: "Weekly", mark: .bar(fill: fill, severity: .critical, value: "", reset: nil, isUsedUp: isUsedUp))
        }
        XCTAssertTrue(row(0, true).isFaded, "used up, shown as left")
        XCTAssertFalse(row(1, true).isFaded, "used up, shown as used")
        XCTAssertFalse(row(0.05, false).isFaded)
    }
}
