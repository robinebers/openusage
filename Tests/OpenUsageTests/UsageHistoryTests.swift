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

    func testDaysAcrossSantiagosClockChangesAreItsDayStarts() throws {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let september6Noon = Date(timeIntervalSince1970: 1_788_706_800)
        let september7Noon = Date(timeIntervalSince1970: 1_788_793_200)

        XCTAssertEqual(UsageHistory.dayStarts(0...2, now: september6Noon, calendar: santiago).map(\.timeIntervalSince1970),
                       [1_788_667_200, 1_788_580_800, 1_788_494_400], "Sep 6 starts at 01:00 and the days before at midnight")
        let september = UsageHistory.dayStarts(0...2, now: september7Noon, calendar: santiago)
        XCTAssertEqual(september[0].timeIntervalSince(september[1]), 23 * 3600, "Sep 6 is 23 hours")
        XCTAssertEqual(september[1].timeIntervalSince(september[2]), 24 * 3600)
        for start in UsageHistory.dayStarts(0..<30, now: september6Noon, calendar: santiago) + september {
            XCTAssertEqual(santiago.startOfDay(for: start), start)
        }
    }

    func testAZeroFromReadDaysConfirmsNoUsageOnlyWhenNoDayFailed() throws {
        let row = HistoryRow.window(.lastDays(2), .tokens)
        let expected = MetricLine.values(label: row.title, values: [MetricValue(number: 0, kind: .count, label: "tokens")])
        var days = [0: UsageDay(totals: .zero([.tokens])), 1: UsageDay(totals: UsageTotals())]

        let sparse = history(days)
        XCTAssertEqual(row.line(label: row.title, in: sparse), expected)
        XCTAssertTrue(try XCTUnwrap(row.breakdown(in: sparse)).isEmpty, "both days were successfully read")

        days[1] = nil
        let partial = history(days)
        XCTAssertEqual(row.line(label: row.title, in: partial), expected, "keep the figure from the day that was read")
        XCTAssertFalse(try XCTUnwrap(row.breakdown(in: partial)).isEmpty, "the other day's activity is unknown")
        XCTAssertNil(row.line(label: row.title, in: history([:])))
    }

    func testARowSumsTheDaysThatReportAFigureAndHidesWhenNoneDo() {
        var days = everyDay(UsageTotals(values: [.spend: 1, .usageEvents: 2, .tokens: 100]))
        days[3] = UsageDay(totals: UsageTotals(values: [.spend: 1, .usageEvents: 2]))
        let history = history(days)

        XCTAssertEqual(HistoryRow.window(.lastDays(30), .spend, then: .tokens).line(label: "Last 30 Days", in: history),
                       .values(label: "Last 30 Days", values: [MetricValue(number: 30, kind: .dollars), MetricValue(number: 2_900, kind: .count, label: "tokens")]))
        XCTAssertNil(HistoryRow.window(.lastDays(30), .requests).line(label: "Last 30 Days", in: history))
        XCTAssertEqual(HistoryRow.measure("Usage Events", .usageEvents, over: .lastDays(30)).line(label: "Usage Events", in: history),
                       .values(label: "Usage Events", values: [MetricValue(number: 60, kind: .count, label: "in 30 days")]))
    }

    func testRestoredWindowsUseTheOriginalReportingDayAfterProviderMidnight() throws {
        let beforeUTC = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-31T23:59:00Z"))
        let afterUTC = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-11-01T00:01:00Z"))
        let utc = Calendar.utc
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc.timeZone)
        func restored(_ window: UsageWindow, calendar: Calendar) throws -> UsageBreakdown {
            let history = UsageHistory(calendar: calendar, asOf: beforeUTC, reported: [window: .zero([.tokens])])
            let detail = try XCTUnwrap(UsageBreakdown(window, in: history))
            return try JSONDecoder().decode(UsageBreakdown.self, from: JSONEncoder().encode(detail))
        }

        let today = try restored(.today, calendar: utc)
        XCTAssertNil(today.archivedTitle(at: beforeUTC))
        XCTAssertEqual(today.archivedTitle(at: afterUTC), beforeUTC.formatted(format))
        let yesterday = try restored(.yesterday, calendar: utc)
        XCTAssertEqual(yesterday.archivedTitle(at: afterUTC), beforeUTC.addingTimeInterval(-86_400).formatted(format))
        XCTAssertNil(try restored(.today, calendar: calendar).archivedTitle(at: afterUTC), "both instants are Nov 1 in Dubai")
    }

    func testEncodedRankingsKeepOnlyTheTopModelsAndOtherForEachFigure() throws {
        let models = Dictionary(uniqueKeysWithValues: (1...15).map { index in
            ("model-\(index)", UsageTotals(values: [.spend: Double(index), .tokens: Double(16 - index)]))
        })
        let day = UsageDay(totals: UsageTotals(values: [.spend: 120, .tokens: 120]), byModel: models)
        let detail = try XCTUnwrap(UsageBreakdown(.today, in: history([0: day])))
        let encoded = try JSONEncoder().encode(detail)
        let saved = try JSONDecoder().decode(UsageBreakdown.self, from: encoded)

        XCTAssertEqual(saved, detail)
        XCTAssertEqual(saved.models(by: .cost).map(\.name), ["model-15", "model-14", "model-13", "model-12", "model-11", "Other"])
        XCTAssertEqual(saved.models(by: .tokens).map(\.name), ["model-1", "model-2", "model-3", "model-4", "model-5", "Other"])
        XCTAssertEqual(saved.models(by: .cost).last?.dollars, 55)
        XCTAssertEqual(saved.models(by: .tokens).last?.tokens, 55)
        for index in 6...10 {
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"model-\(index)\""))
        }
    }

    func testModelsNoOneWasChargedForRankByTokensWithNoDollars() throws {
        let byModel = [
            "a": UsageTotals(values: [.spend: 0, .tokens: 100]),
            "b": UsageTotals(values: [.spend: 0, .tokens: 900]),
        ]
        let days = [0: UsageDay(totals: UsageTotals(values: [.spend: 0, .tokens: 1_000]), byModel: byModel)]

        let today = try XCTUnwrap(UsageBreakdown(.today, in: history(days)))

        XCTAssertEqual(today.modelFigures, [.tokens])
        XCTAssertEqual(today.models.map(\.name), ["b", "a"])
        XCTAssertEqual(today.models.map(\.dollars), [nil, nil])
    }

    func testUnattributedUsageCountsTowardTotalsWhileModelFiguresShowOnlyReportedAmounts() throws {
        let attributed = UsageDay(
            totals: UsageTotals(values: [.spend: 10, .tokens: 100]),
            byModel: ["a": UsageTotals(values: [.spend: 8, .tokens: 40]), "b": UsageTotals(values: [.spend: 2])]
        )
        let unsplit = UsageDay(totals: UsageTotals(values: [.spend: 100, .tokens: 100_000]))
        let range = try XCTUnwrap(UsageBreakdown(.lastDays(2), in: history([0: attributed, 1: unsplit])))

        XCTAssertEqual(range.totals[.spend], 110)
        XCTAssertEqual(range.totals[.tokens], 100_100)
        XCTAssertEqual(range.models(by: .cost).map(\.name), ["a", "b"])
        XCTAssertEqual(range.models(by: .cost).map(\.dollars), [8, 2])
        XCTAssertEqual(range.models(by: .tokens).map(\.name), ["a"])
        XCTAssertEqual(range.models(by: .tokens).map(\.tokens), [40])
    }

    func testModelSharesUseReportedCreditsAndFallBackToTurnsWithoutAPositiveCreditTotal() throws {
        var charged = UsageDay(totals: UsageTotals(values: [.credits: 8, .turns: 10]), byModel: [
            "billed": UsageTotals(values: [.credits: 2]), "turns-only": UsageTotals(values: [.turns: 10])
        ])
        let recent = UsageDay(totals: UsageTotals(values: [.turns: 4]), byModel: ["turns-only": UsageTotals(values: [.turns: 4])])
        func range() throws -> UsageBreakdown {
            try XCTUnwrap(UsageBreakdown(.lastDays(2), in: history([0: recent, 1: charged])))
        }

        let credits = try range()
        XCTAssertEqual(credits.totals[.credits], 8, "today reported only turns")
        XCTAssertEqual(credits.models.map(\.name), ["billed"])
        XCTAssertEqual(credits.models.first?.share, 0.25, "two of the eight reported credits were attributed")

        charged.byModel?["refund"] = UsageTotals(values: [.credits: -1])
        XCTAssertEqual(try range().models.last?.share, -0.125, "a credit adjustment keeps its sign")

        for total in [nil, 0] as [Double?] {
            charged.totals.values[.credits] = total
            let turns = try range()
            XCTAssertEqual(turns.totals[.credits], total)
            XCTAssertEqual(turns.models.map(\.name), ["turns-only"])
            XCTAssertEqual(turns.models.first?.share, 1)
        }
    }

    func testTheFiguresLeadWithDollarsAndBYOKShowsOnlyWhenSpent() throws {
        func figures(_ values: [UsageMeasure: Double]) throws -> [String] {
            try XCTUnwrap(UsageBreakdown(.today, in: history([0: UsageDay(totals: UsageTotals(values: values))]))).figures
        }
        XCTAssertEqual(try figures([.spend: 12.5, .usageEvents: 9, .tokens: 3_000, .byokSpend: 0]), ["$12.50", "3K tokens"])
        XCTAssertEqual(try figures([.spend: 12.5, .byokSpend: 2, .tokens: 3_000]), ["$12.50", "3K tokens", "$2 BYOK"])
        XCTAssertEqual(try figures([.tokens: 3_000]), ["3K tokens"])
        XCTAssertEqual(try figures([.requests: 8]), ["8 requests"], "a legacy plan reports nothing else")
    }

    func testTokenPartsAreLargestFirstAndABarNeedsThemToAddUpToTheTotal() throws {
        func breakdown(_ values: [UsageMeasure: Double]) throws -> UsageBreakdown {
            try XCTUnwrap(UsageBreakdown(.today, in: history([0: UsageDay(totals: UsageTotals(values: values))])))
        }
        let split = try breakdown([.tokens: 100, .inputTokens: 10, .cacheReadTokens: 80, .cacheWriteTokens: 0, .outputTokens: 10])
        XCTAssertEqual(split.tokenParts.map(\.title), ["Cache Read", "Input", "Output"])
        XCTAssertTrue(split.tokenPartsFillTotal)

        let cachedInsideInput = try breakdown([.tokens: 660, .inputTokens: 600, .cacheReadTokens: 200, .outputTokens: 60])
        XCTAssertFalse(cachedInsideInput.tokenPartsFillTotal, "cached tokens are already part of input")
    }
}

extension UsageBreakdown {
    /// The ranking shown when the user has no saved figure preference.
    var models: [Model] { modelFigures.first.map(models(by:)) ?? [] }
}
