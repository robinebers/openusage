import XCTest
@testable import OpenUsage

/// Covers `SpendTileMapper.appendTokenUsage`'s no-usage handling.
///
/// A period with no usage (an idle day the source didn't report, or a day it reported as zero) is left
/// unbacked so the tile reads "No data" rather than a fabricated "$0.00 · 0 tokens" that contradicts a
/// live Session/Weekly meter proving otherwise. This holds for every source — the Claude/Codex/Grok
/// log scanners, Cursor's CSV — with no per-source branching. The Usage Trend is unaffected; it
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

    func testSingleModelPeriodStillGetsModelBreakdown() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.totalTokens, 300)
        XCTAssertEqual(breakdown.totalCostUSD, 3)
        XCTAssertEqual(breakdown.models, [
            ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
        ])
    }

    func testModelBreakdownISODateMatchesLocalPeriodDay() throws {
        let now = day(2026, 6, 26)
        let localStart = Calendar.current.startOfDay(for: now)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: dayKey(now), totalTokens: 300, costUSD: 3)
            ]),
            to: &lines,
            now: now,
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: isoString(localStart), models: [
                    ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["gpt-5.5"])
    }

    func testModelBreakdownScopesTodayYesterdayAndLast30() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 700, costUSD: 7)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                    ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
                ]),
                DailyModelUsageEntry(date: "2026-06-25", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 300, costUSD: 3),
                    ModelUsageEntry(model: "gamma", totalTokens: 400, costUSD: 4)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let today = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(today.totalTokens, 300)
        XCTAssertEqual(today.totalCostUSD, 3)
        XCTAssertEqual(today.models.map(\.model), ["beta", "alpha"])

        let yesterday = try XCTUnwrap(modelBreakdown(lines, "Yesterday"))
        XCTAssertEqual(yesterday.models.map(\.model), ["gamma", "alpha"])

        let last30 = try XCTUnwrap(modelBreakdown(lines, "Last 30 Days"))
        XCTAssertEqual(last30.totalTokens, 1000)
        XCTAssertEqual(last30.totalCostUSD, 10)
        XCTAssertEqual(last30.models.map(\.model), ["alpha", "gamma", "beta"])
        XCTAssertEqual(last30.sourceNote, "From test logs")
    }

    func testModelBreakdownSortsFoldsOtherAndKeepsUnpricedNamed() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 3_700, costUSD: 49)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 10),
                    ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 9),
                    ModelUsageEntry(model: "aardvark", totalTokens: 300, costUSD: 9),
                    ModelUsageEntry(model: "delta", totalTokens: 400, costUSD: 7),
                    ModelUsageEntry(model: "epsilon", totalTokens: 500, costUSD: 6),
                    ModelUsageEntry(model: "zeta", totalTokens: 600, costUSD: 5),
                    ModelUsageEntry(model: "eta", totalTokens: 700, costUSD: 3),
                    ModelUsageEntry(model: "mystery", totalTokens: 900, costUSD: nil)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        // The unpriced "mystery" puts the whole list on token shares (the basis the panel's percent
        // labels use), so "alpha" — top spend but only 100 of 3,700 tokens (~3%) — folds into Other
        // along with over-the-cap "eta". The sort still ranks by cost first.
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(
            breakdown.models.map(\.model),
            ["aardvark", "beta", "delta", "epsilon", "zeta", "mystery", "Other"]
        )
        let other = try XCTUnwrap(breakdown.models.first { $0.model == "Other" })
        XCTAssertEqual(other.totalTokens, 800)
        XCTAssertEqual(other.costUSD, 13)
        XCTAssertEqual(other.variants?.map(\.model), ["alpha", "eta"],
                       "the Other row's tooltip lists the folded models, largest spend first")
        XCTAssertNil(breakdown.models.first { $0.model == "mystery" }?.costUSD)
    }

    func testModelBreakdownFoldsSubFivePercentModelsIntoOther() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 1_000, costUSD: 100)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "big", totalTokens: 700, costUSD: 90),
                    ModelUsageEntry(model: "mid", totalTokens: 200, costUSD: 6),
                    ModelUsageEntry(model: "tiny", totalTokens: 100, costUSD: 4)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        // All priced → cost shares: 90% / 6% / 4%. "tiny" is under the 5% floor and folds into Other
        // even though the named-model cap has room.
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["big", "mid", "Other"])
        let other = try XCTUnwrap(breakdown.models.first { $0.model == "Other" })
        XCTAssertEqual(other.costUSD, 4)
        XCTAssertEqual(other.variants?.map(\.model), ["tiny"])
    }

    func testModelBreakdownFoldsUnattributedIntoOtherRegardlessOfSize() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 1_000, costUSD: 6)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "grok-build", totalTokens: 600, costUSD: 6),
                    // 40% of tokens — well above the 5% floor, still folds.
                    ModelUsageEntry(model: ModelUsageEntry.unattributedModelName, totalTokens: 400, costUSD: nil)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["grok-build", "Other"],
                       "unattributed tokens read as Other, never as their own row")
        let other = try XCTUnwrap(breakdown.models.first { $0.model == "Other" })
        XCTAssertEqual(other.totalTokens, 400)
        XCTAssertNil(other.costUSD)
    }

    func testModelBreakdownGroupsCaseInsensitivelyAndKeepsDominantSpelling() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 400, costUSD: 4)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "GLM-5.2", totalTokens: 100, costUSD: 1),
                    ModelUsageEntry(model: "glm-5.2", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["glm-5.2"],
                       "case variants collapse into one row titled with the dominant spelling")
        let merged = breakdown.models[0]
        XCTAssertEqual(merged.totalTokens, 400)
        XCTAssertEqual(merged.costUSD, 4)
        XCTAssertNil(merged.variants, "casing differences are not a real breakdown")
    }

    func testModelBreakdownMergesVariantsAcrossDays() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 400, costUSD: 4)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 300, costUSD: 3, variants: [
                        ModelUsageVariant(model: "opus-thinking-max", totalTokens: 300, costUSD: 3)
                    ])
                ]),
                DailyModelUsageEntry(date: "2026-06-25", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 400, costUSD: 4, variants: [
                        ModelUsageVariant(model: "opus-thinking-max", totalTokens: 100, costUSD: 1),
                        ModelUsageVariant(model: "opus-thinking-high", totalTokens: 300, costUSD: 3)
                    ])
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let last30 = try XCTUnwrap(modelBreakdown(lines, "Last 30 Days"))
        let opus = try XCTUnwrap(last30.models.first { $0.model == "opus" })
        XCTAssertEqual(opus.totalTokens, 700)
        XCTAssertEqual(opus.costUSD, 7)
        XCTAssertEqual(opus.variants?.map(\.model), ["opus-thinking-max", "opus-thinking-high"],
                       "the same slug merges into one line across the period's days")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [4, 3])
        XCTAssertEqual(opus.variants?.map(\.totalTokens), [400, 300])
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

    private func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func line(_ lines: [MetricLine], _ label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = line(lines, label) else { return nil }
        return values
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = line(lines, label) else { return nil }
        return breakdown
    }
}
