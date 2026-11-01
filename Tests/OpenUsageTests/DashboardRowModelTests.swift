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

    func testABoundedReadingIsABarWithItsValueAndResetAndAnUnboundedOneAValue() {
        let bar = paced(used: 30).dashboardRow(now: now)
        XCTAssertEqual(bar.label, "Weekly")
        XCTAssertEqual(bar.mark, .bar(fill: 0.7, severity: .normal, value: "70% left", reset: "Resets in 3d 12h"))

        var credits = WidgetData(title: "Credits", kind: .count, used: 452, limit: nil)
        credits.values = [MetricValue(number: 452, kind: .count, label: "credits")]
        XCTAssertEqual(credits.dashboardRow(now: now).mark, .value("452 credits"))

        var resets = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
        resets.values = [MetricValue(number: 2, kind: .count, label: "available")]
        resets.showsResetExpiries = true
        XCTAssertEqual(resets.dashboardRow(now: now).mark, .value("2 available"))
    }

    func testTheResetsFigureWarnsInTheColourOfTheResetThatExpiresNext() {
        var resets = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
        resets.values = [MetricValue(number: 2, kind: .count, label: "available")]
        resets.showsResetExpiries = true
        let day: TimeInterval = 24 * 3600
        let cases: [(expiries: [TimeInterval], severity: WidgetData.MeterSeverity)] = [
            ([], .normal),
            ([10 * day], .normal),
            ([3 * day, 20 * day], .warning),
            ([20 * day, 1 * day], .critical),
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
        XCTAssertEqual(paced(used: 60).dashboardRow(now: now).mark, .bar(fill: 0.4, severity: .critical, value: "40% left", reset: "Resets in 3d 12h"))
        XCTAssertEqual(paced(used: 93, elapsed: 0.2).dashboardRow(now: now).mark, .bar(fill: 0.07, severity: .critical, value: "7% left", reset: "Resets in 5d 14h"))
        XCTAssertEqual(paced(used: 49).dashboardRow(now: now).mark, .bar(fill: 0.51, severity: .warning, value: "51% left", reset: "Resets in 3d 12h"))
        XCTAssertEqual(paced(used: 85, elapsed: 0.9).dashboardRow(now: now).mark, .bar(fill: 0.15, severity: .warning, value: "15% left", reset: "Resets in 16h 48m"))
        XCTAssertEqual(paced(used: 30).dashboardRow(now: now).mark, .bar(fill: 0.7, severity: .normal, value: "70% left", reset: "Resets in 3d 12h"))
        XCTAssertEqual(paced(used: 76, elapsed: 0.9).dashboardRow(now: now).mark, .bar(fill: 0.24, severity: .normal, value: "24% left", reset: "Resets in 16h 48m"))
        for (used, severity) in [(74.0, WidgetData.MeterSeverity.normal), (75, .warning), (89, .warning), (90, .critical)] {
            var noWindow = WidgetData(title: "Credits", kind: .dollars, used: used, limit: 100)
            noWindow.displayMode = .remaining
            XCTAssertEqual(noWindow.dashboardRow(now: now).mark, .bar(fill: (100 - used) / 100, severity: severity, value: "$\(Int(100 - used)) left", reset: nil), "$\(used) of $100")
        }
    }

    func testAUsedUpLimitIsMarkedAndKeepsItsOrdinaryResetLine() {
        XCTAssertEqual(paced(used: 100).dashboardRow(now: now).mark, .bar(fill: 0, severity: .critical, value: "0% left", reset: "Resets in 3d 12h", isUsedUp: true))
        var used = paced(used: 100)
        used.displayMode = .used
        XCTAssertEqual(used.dashboardRow(now: now).mark, .bar(fill: 1, severity: .critical, value: "100% used", reset: "Resets in 3d 12h", isUsedUp: true))
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

    func testTheResetFollowsTheClockSettingAndReadsSoonWhenDue() {
        var data = paced(used: 30)
        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.compactResetText(now: now), Formatters.compactClock(data.resetsAt!, now: now))
        data.resetDisplayMode = .relative
        data.resetsAt = now.addingTimeInterval(86 * 60)
        XCTAssertEqual(data.compactResetText(now: now), "1h 26m")
        data.resetsAt = now.addingTimeInterval(-1)
        XCTAssertEqual(data.compactResetText(now: now), "soon")
    }

    func testTheResetLabelSaysResetsInForACountdownAndResetsForAClockTime() {
        var data = paced(used: 30)
        data.resetsAt = now.addingTimeInterval(22 * 3600 + 10 * 60)
        XCTAssertEqual(data.resetLabel(now: now), "Resets in 22h 10m")
        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.resetLabel(now: now), "Resets \(Formatters.compactClock(data.resetsAt!, now: now))")
        data.resetDisplayMode = .relative
        data.resetsAt = now.addingTimeInterval(-1)
        XCTAssertEqual(data.resetLabel(now: now), "Resets soon")
        XCTAssertNil(WidgetData(title: "On-demand", kind: .dollars, used: 12, limit: 20).resetLabel(now: now))
    }

    func testAFreshSessionACapWithoutAResetAndABadgeLeaveTheResetEmpty() {
        var fresh = paced(used: 0, elapsed: 0.1, period: 5 * 3600, title: "Session")
        fresh.sessionStartSignal = .zeroUsage
        XCTAssertEqual(fresh.dashboardRow(now: now).mark, .bar(fill: 1, severity: .normal, value: "100% left", reset: nil))

        let dollars = WidgetData(title: "On-demand", kind: .dollars, used: 12, limit: 20)
        XCTAssertEqual(dollars.dashboardRow(now: now).mark, .bar(fill: 0.6, severity: .normal, value: "$12 used", reset: nil))

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
}
