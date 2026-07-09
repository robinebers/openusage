import XCTest
@testable import OpenUsage

/// Covers the Usage Trend feature: the per-day token sparkline built from scanned daily data, its
/// chart `MetricLine`, and how it flows through the descriptor / data store (non-pinnable, no-data safe).
@MainActor
final class UsageTrendTests: XCTestCase {
    func testAppendUsageTrendZeroFillsTheCalendarWindow() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-21", totalTokens: 222_000_000, costUSD: nil),
                DailyUsageEntry(date: "2026-06-19", totalTokens: 500, costUSD: nil),
                DailyUsageEntry(date: "2026-06-20", totalTokens: 1_500_000, costUSD: nil)
            ]),
            to: &lines,
            now: date(2026, 6, 21),
            note: "Estimated from local Claude logs at API rates."
        )

        guard case .chart(let label, let points, let note) = lines.first else {
            return XCTFail("expected a chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        XCTAssertEqual(note, "Estimated from local Claude logs at API rates.")
        // One bar per calendar day across the 31-day window (today + 30 back), oldest first.
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.first?.label, dayLabel(2026, 5, 22), "window starts 30 days before today")
        XCTAssertEqual(points.last?.label, dayLabel(2026, 6, 21), "window ends today")
        XCTAssertEqual(Set(points.map(\.label)).count, 31, "every day in the window is a distinct bar")
        // Labels are the app's month/day style ("Jun 21"), not the old hardcoded "6/21" — pinned without
        // a locale-specific literal: no slash, and a month name rather than a bare number.
        let lastLabel = try XCTUnwrap(points.last?.label)
        XCTAssertFalse(lastLabel.contains("/"), "not the old numeric M/d format")
        XCTAssertTrue(lastLabel.contains(where: \.isLetter), "carries a localized month name")
        // The three active days carry their tokens; every other day is a zero bar, not a dropped gap.
        XCTAssertEqual(points[28].value, 500)          // 6/19
        XCTAssertEqual(points[29].value, 1_500_000)    // 6/20
        XCTAssertEqual(points[30].value, 222_000_000)  // 6/21
        XCTAssertEqual(points[0].value, 0, "an idle day is a zero bar")
        // Pre-formatted readouts: compact counts with a "tokens" unit.
        XCTAssertEqual(points[28...30].map(\.valueLabel), ["500 tokens", "1.5M tokens", "222M tokens"])
        XCTAssertEqual(points[0].valueLabel, "0 tokens")
    }

    func testTrendZeroFillsGapsBetweenActiveDays() {
        // Usage on 6/19 and 6/21 but none on 6/20: the gap stays in place as a zero bar rather than
        // collapsing the two active days into neighbors.
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-19", totalTokens: 500, costUSD: nil),
                DailyUsageEntry(date: "2026-06-21", totalTokens: 222_000_000, costUSD: nil)
            ]),
            to: &lines, now: date(2026, 6, 21), note: "n"
        )

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points[28].label, dayLabel(2026, 6, 19))
        XCTAssertEqual(points[29].label, dayLabel(2026, 6, 20))
        XCTAssertEqual(points[29].value, 0, "the gap day is a zero bar, not removed")
        XCTAssertEqual(points[30].label, dayLabel(2026, 6, 21))
    }

    func testTrendWindowEndsAtTodayEvenWhenUsageIsOlder() {
        // Last activity was 6/19 but today is 6/21: the window still ends today, so the two trailing
        // idle days are zero bars rather than the chart stopping at the last active day.
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-06-19", totalTokens: 500, costUSD: nil)]),
            to: &lines, now: date(2026, 6, 21), note: "n"
        )

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points.last?.label, dayLabel(2026, 6, 21))
        XCTAssertEqual(points[28].value, 500, "the one active day keeps its tokens")
        XCTAssertEqual(points[29].value, 0)
        XCTAssertEqual(points[30].value, 0)
    }

    func testTrendDropsDaysOlderThanTheWindow() {
        // 40 distinct days (May 1–31, then June 1–9) with today = 6/9. The window is the 31 days ending
        // today (5/10 … 6/9), so May 1–9 fall outside it and are dropped.
        var daily = (1...31).map { DailyUsageEntry(date: String(format: "2026-05-%02d", $0), totalTokens: $0 * 1000, costUSD: nil) }
        daily += (1...9).map { DailyUsageEntry(date: String(format: "2026-06-%02d", $0), totalTokens: $0 * 1000, costUSD: nil) }

        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(DailyUsageSeries(daily: daily), to: &lines, now: date(2026, 6, 9), note: "n")

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.first?.label, dayLabel(2026, 5, 10), "days older than 30 back are outside the window")
        XCTAssertEqual(points.last?.label, dayLabel(2026, 6, 9), "window ends today")
    }

    func testTrendAggregatesDuplicateDaysAndParsesCompactDates() {
        // Two source rows that normalize to the same calendar day (8-digit + hyphenated) collapse into
        // one bar carrying their summed tokens, not two bars splitting it.
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "20260620", totalTokens: 1000, costUSD: nil),
                DailyUsageEntry(date: "2026-06-20", totalTokens: 500, costUSD: nil)
            ]),
            to: &lines, now: date(2026, 6, 20), note: "n"
        )

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points.last?.label, dayLabel(2026, 6, 20))
        XCTAssertEqual(points.last?.value, 1500, "the day's tokens are summed, not split across bars")
    }

    func testAppendUsageTrendSkippedWhenWindowHasNoUsage() {
        // No rows at all, and rows that are all zero, both leave "No data" rather than a flat zero chart.
        var empty: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(DailyUsageSeries(daily: []), to: &empty, now: date(2026, 6, 21), note: "n")
        XCTAssertTrue(empty.isEmpty, "no rows means no chart")

        var allZero: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-06-20", totalTokens: 0, costUSD: nil)]),
            to: &allZero, now: date(2026, 6, 21), note: "n"
        )
        XCTAssertTrue(allZero.isEmpty, "a fully idle window has no trend to draw")
    }

    func testChartLineCodableRoundTrips() throws {
        let line = MetricLine.chart(
            label: "Usage Trend",
            points: [MetricChartPoint(value: 1_500_000, label: "6/20", valueLabel: "1.5M tokens")],
            note: "src"
        )
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: data)
        XCTAssertEqual(decoded, line)
    }

    func testUsageTrendDescriptorIsNotPinnable() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
        XCTAssertEqual(descriptor.id, "claude.trend")
        XCTAssertFalse(descriptor.pinnable)
        XCTAssertTrue(descriptor.sample.isChart)

        let suite = makeDefaults("pinnable")
        let store = LayoutStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            defaults: suite,
            storageKey: "layout"
        )
        XCTAssertFalse(store.canPin("claude.trend"), "a chart can't be drawn in the tray, so it can't be pinned")
    }

    func testDataStoreResolvesChartLineToAChartTile() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
        let store = makeDataStore(provider: provider, descriptor: descriptor)
        store.snapshots["claude"] = ProviderSnapshot(
            providerID: "claude", displayName: "Claude",
            lines: [.chart(label: "Usage Trend",
                           points: [MetricChartPoint(value: 5000, label: "6/20", valueLabel: "5K tokens")],
                           note: "src")]
        )

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.isChart)
        XCTAssertTrue(data.hasData)
        XCTAssertEqual(data.chartPoints.count, 1)
        XCTAssertEqual(data.chartNote, "src")
    }

    func testChartTileWithoutABackingLineRendersNoData() {
        // A placed row with no `.chart` line must not treat descriptor template data as live usage — it
        // falls back to the no-data state.
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
        let store = makeDataStore(provider: provider, descriptor: descriptor)

        let data = store.data(for: descriptor)
        XCTAssertFalse(data.hasData)
    }

    // The hover-reveal coordinator is now the shared `HoverPopoverState`, covered once in
    // ModelUsageHoverTests (open/close-around-both-regions, quick-pass, dismiss).

    // MARK: - Helpers

    /// A fixed `now` at midday in the current calendar, so `startOfDay` math is stable regardless of the
    /// machine's clock and the day-key strings line up with the hyphenated input dates.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// The expected axis label for a day, in the app's localized month/day style — via the same shared
    /// formatter the producer uses, so the slot-mapping assertions hold in any test-machine locale.
    private func dayLabel(_ year: Int, _ month: Int, _ day: Int) -> String {
        Formatters.monthDayLabel(date(year, month, day))
    }

    private func makeDataStore(provider: Provider, descriptor: WidgetDescriptor) -> WidgetDataStore {
        let runtime = TestProviderRuntime(
            provider: provider, descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeDefaults("trend")
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Trend.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
