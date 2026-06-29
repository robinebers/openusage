import XCTest
@testable import OpenUsage

/// Covers `SpendTileMapper.appendTokenUsage`'s no-usage handling.
///
/// A period with no usage (an idle day the source didn't report, or a day it reported as zero) is left
/// unbacked so the tile reads "No data" rather than a fabricated "$0.00 · 0 tokens" that contradicts a
/// live Session/Weekly meter proving otherwise. This holds for every source — ccusage (Claude/Codex),
/// the Grok CLI log, Cursor's CSV — with no per-source branching. The Usage Trend is unaffected; it
/// still zero-fills the window (see `UsageTrendTests`).
final class SpendTileMapperTests: XCTestCase {
    func testIdleRecentDaysLeftUnbacked() {
        // The source's last reported day is 3 days before today: today and yesterday are idle.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-22", 5_000), ("2026-06-23", 7_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertNil(line(lines, "Today"), "an idle today is left unbacked → tile reads No data")
        XCTAssertNil(line(lines, "Yesterday"), "ditto yesterday — not a fabricated $0.00")
        XCTAssertNotNil(line(lines, "Last 30 Days"), "the 30-day total still renders")
    }

    func testInRangeIdleDayAlsoLeftUnbacked() {
        // Used today and two days ago but not yesterday: a zero-token yesterday is "No data" too, not a
        // measured $0.00 — the branch between "absent" and "in-range zero" is gone. (Tokens-only rows
        // carry no cost — these series have costUSD nil — so a used day shows just its token count.)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-24", 9_000), ("2026-06-26", 3_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 3_000, kind: .count, label: "tokens")])
        XCTAssertNil(line(lines, "Yesterday"), "an idle in-range day is No data, not $0.00 · 0 tokens")
    }

    func testEmptySeriesLeavesAllTilesUnbacked() {
        // The source ran but found nothing in the whole window (e.g. a brand-new user): every period is
        // idle, so nothing is appended and all three tiles read "No data".
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: []), to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertTrue(lines.isEmpty, "an all-zero window appends no spend tiles")
    }

    func testUsedDayRendersItsValues() {
        // A day with real usage renders its token count (and cost, when the source prices it).
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-06-26", totalTokens: 12_000, costUSD: 1.50)]),
            to: &lines, now: day(2026, 6, 26), estimated: true
        )

        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 1.50, kind: .dollars, estimated: true),
                        MetricValue(number: 12_000, kind: .count, label: "tokens")])
    }

    // MARK: - Helpers

    private func series(_ days: [(String, Int)]) -> DailyUsageSeries {
        DailyUsageSeries(daily: days.map { DailyUsageEntry(date: $0.0, totalTokens: $0.1, costUSD: nil) })
    }

    /// A fixed instant at midday in the current calendar, so `dayKey(from:)` and the hyphenated input
    /// dates line up regardless of the test machine's clock.
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func line(_ lines: [MetricLine], _ label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _) = line(lines, label) else { return nil }
        return values
    }
}
