import XCTest
@testable import OpenUsage

final class UsageHistoryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        return calendar
    }()
    /// 00:30 on 31 October in Dubai, still 30 October in UTC.
    private let now = Date(timeIntervalSince1970: 1_793_392_200)

    private func history(_ days: [Int: UsageDay]) -> UsageHistory {
        let starts = UsageHistory.dayStarts(0..<30, now: now, calendar: calendar)
        return UsageHistory(calendar: calendar, asOf: now, days: Dictionary(uniqueKeysWithValues: days.map { (starts[$0.key], $0.value) }))
    }

    private func everyDay(_ totals: UsageTotals) -> [Int: UsageDay] {
        Dictionary(uniqueKeysWithValues: (0..<30).map { ($0, UsageDay(totals: totals)) })
    }

    func testASumKeepsOnlyTheMeasuresEveryPartReports() {
        let sum = UsageTotals(values: [.spend: 1, .tokens: 10]).adding(UsageTotals(values: [.spend: 2, .usageEvents: 4]))

        XCTAssertEqual(sum.values, [.spend: 3])
    }

    func testDaysAreLocalDaysRunningBackFromToday() {
        XCTAssertEqual(
            UsageHistory.dayStarts(0...1, now: now, calendar: calendar),
            [Date(timeIntervalSince1970: 1_793_390_400), Date(timeIntervalSince1970: 1_793_304_000)]
        )
    }

    func testAReportedZeroShowsAndAWindowWithAnUnreadDayHides() {
        let row = HistoryRow.window(.lastDays(30), .spend, then: .tokens)
        var days = everyDay(.zero(CursorUsageEvents.measures))

        XCTAssertEqual(row.line(label: "Last 30 Days", in: history(days)), .values(label: "Last 30 Days", values: [
            MetricValue(number: 0, kind: .dollars), MetricValue(number: 0, kind: .count, label: "tokens")
        ]))

        days[29] = nil
        XCTAssertNil(row.line(label: "Last 30 Days", in: history(days)))
        XCTAssertNotNil(HistoryRow.window(.today, .spend).line(label: "Today", in: history(days)))
    }

    func testARowShowsTheFiguresEveryDayReportedAndHidesWhenNoneResolve() {
        var days = everyDay(UsageTotals(values: [.spend: 1, .usageEvents: 2, .tokens: 100]))
        days[3] = UsageDay(totals: UsageTotals(values: [.spend: 1, .usageEvents: 2]))
        let history = history(days)

        XCTAssertEqual(HistoryRow.window(.lastDays(30), .spend, then: .tokens).line(label: "Last 30 Days", in: history),
                       .values(label: "Last 30 Days", values: [MetricValue(number: 30, kind: .dollars)]))
        XCTAssertNil(HistoryRow.window(.lastDays(30), .tokens).line(label: "Last 30 Days", in: history))
        XCTAssertEqual(HistoryRow.measure("Usage Events", .usageEvents, over: .lastDays(30)).line(label: "Usage Events", in: history),
                       .values(label: "Usage Events", values: [MetricValue(number: 60, kind: .count, label: "in 30 days")]))
    }

    func testABreakdownRanksTheTopFiveModelsAndFoldsTheRestIntoOther() throws {
        let models = Dictionary(uniqueKeysWithValues: (1...7).map {
            ("model-\($0)", UsageTotals(values: [.usageEvents: 1, .tokens: Double($0 * 10)]))
        })
        let history = history([0: UsageDay(totals: UsageTotals(values: [.usageEvents: 7, .tokens: 280]), byModel: models)])

        let breakdown = try XCTUnwrap(UsageBreakdown(.today, in: history))

        XCTAssertEqual(breakdown.models.map(\.name), ["model-7", "model-6", "model-5", "model-4", "model-3", "Other"])
        XCTAssertEqual(breakdown.models.map(\.number), [70, 60, 50, 40, 30, 30])
        XCTAssertEqual(breakdown.modelMeasure, .tokens)
        XCTAssertEqual(breakdown.models.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testABreakdownRanksByUsageEventsWhenAModelsTokensWereNotReportedAndNeedsEveryDaySplit() throws {
        let byModel = ["a": UsageTotals(values: [.usageEvents: 1, .tokens: 900]), "b": UsageTotals(values: [.usageEvents: 3])]
        var days = [0: UsageDay(totals: UsageTotals(values: [.usageEvents: 4]), byModel: byModel)]

        let today = try XCTUnwrap(UsageBreakdown(.today, in: history(days)))
        XCTAssertEqual(today.modelMeasure, .usageEvents)
        XCTAssertEqual(today.models.map(\.number), [3, 1])

        days[1] = UsageDay(totals: UsageTotals(values: [.usageEvents: 4]))
        XCTAssertEqual(UsageBreakdown(.lastDays(2), in: history(days))?.models, [], "a day not split by model hides the models")
        XCTAssertNil(UsageBreakdown(.lastDays(3), in: history(days)), "an unread day hides the whole breakdown")
    }
}
