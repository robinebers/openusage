import XCTest
@testable import OpenUsage

/// Covers `SpendTileMapper.appendTokenUsage`'s handling of recent days that the source didn't report.
///
/// ccusage (Claude/Codex) omits idle days and can lag a CLI format change, so a Today/Yesterday it never
/// returns is *unknown*, not a measured zero — those tiles must read "No data" (no backing line) rather
/// than a fabricated "$0.00 · 0 tokens" that contradicts the live Session/Weekly meters. Sources that read
/// a complete local log (Grok) or a full export (Cursor) keep the documented behavior: a recent idle day
/// is a real zero. The Usage Trend is unaffected — it still zero-fills the window (see `UsageTrendTests`).
final class SpendTileMapperTests: XCTestCase {
    // A measured zero day: "$0.00 · 0 tokens". `estimated: false` matches the flag the tests pass below.
    private let zero = [
        MetricValue(number: 0, kind: .dollars, estimated: false),
        MetricValue(number: 0, kind: .count, label: "tokens")
    ]

    func testRecentDaysBeyondCoverageLeaveTilesUnbackedWhenSourceCannotVouch() {
        // ccusage's last reported day is 3 days before today: today and yesterday are beyond its coverage.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-22", 5_000), ("2026-06-23", 7_000)]),
            to: &lines, now: day(2026, 6, 26), missingRecentDaysUnknown: true
        )

        XCTAssertNil(line(lines, "Today"), "an uncaptured recent day is left unbacked → tile reads No data")
        XCTAssertNil(line(lines, "Yesterday"), "ditto yesterday — not a fabricated $0.00")
        XCTAssertNotNil(line(lines, "Last 30 Days"), "the 30-day total still renders")
    }

    func testInRangeIdleDayStaysMeasuredZeroEvenWhenRecentUnknown() {
        // Used today and two days ago but not yesterday: today anchors coverage, so yesterday's gap is a
        // real measured zero, while a hypothetical future day would still be unknown. (Tokens-only rows
        // carry no cost — these series have costUSD nil — so a used day shows just its token count.)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-24", 9_000), ("2026-06-26", 3_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false, missingRecentDaysUnknown: true
        )

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 3_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), zero, "an idle day within the reported range is a real zero")
    }

    func testCompleteSourcesStillShowRealZeroForRecentIdleDays() {
        // The default (Grok/Cursor): they read a complete source, so a recent absent day is a confident
        // measured zero — never collapsed to No data.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-22", 5_000), ("2026-06-23", 7_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertEqual(values(lines, "Today"), zero)
        XCTAssertEqual(values(lines, "Yesterday"), zero)
    }

    func testEmptySeriesStaysZeroEvenWhenRecentUnknown() {
        // ccusage ran and found nothing in the whole window (e.g. a brand-new user): a genuine all-zero
        // result, not a coverage gap — so today/yesterday stay $0.00 rather than No data.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: []), to: &lines, now: day(2026, 6, 26), estimated: false, missingRecentDaysUnknown: true
        )

        XCTAssertEqual(values(lines, "Today"), zero)
        XCTAssertEqual(values(lines, "Yesterday"), zero)
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
        guard case .values(_, let values, _, _, _) = line(lines, label) else { return nil }
        return values
    }
}
