import XCTest
@testable import OpenUsage

/// Covers the Usage Trend feature: the per-day token sparkline built from ccusage daily data, its
/// chart `MetricLine`, and how it flows through the descriptor / data store (non-pinnable, no-data safe).
@MainActor
final class UsageTrendTests: XCTestCase {
    func testAppendUsageTrendBuildsChronologicalTokenPoints() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            CcusageDailyUsage(daily: [
                CcusageDay(date: "2026-06-21", totalTokens: 222_000_000, costUSD: nil),
                CcusageDay(date: "2026-06-19", totalTokens: 500, costUSD: nil),
                CcusageDay(date: "2026-06-20", totalTokens: 1_500_000, costUSD: nil)
            ]),
            to: &lines,
            note: "Estimated from local Claude logs at API rates."
        )

        guard case .chart(let label, let points, let note) = lines.first else {
            return XCTFail("expected a chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        XCTAssertEqual(note, "Estimated from local Claude logs at API rates.")
        // Sorted ascending by date, regardless of input order.
        XCTAssertEqual(points.map(\.label), ["6/19", "6/20", "6/21"])
        XCTAssertEqual(points.map(\.value), [500, 1_500_000, 222_000_000])
        // Pre-formatted readouts: compact counts with a "tokens" unit.
        XCTAssertEqual(points.map(\.valueLabel), ["500 tokens", "1.5M tokens", "222M tokens"])
    }

    func testAppendUsageTrendKeepsTheMostRecent31Days() {
        // 40 distinct days (May 1–31, then June 1–9). The chart keeps the most recent 31, dropping the
        // oldest nine — so it starts at 5/10, not 5/1.
        var daily = (1...31).map { CcusageDay(date: String(format: "2026-05-%02d", $0), totalTokens: $0 * 1000, costUSD: nil) }
        daily += (1...9).map { CcusageDay(date: String(format: "2026-06-%02d", $0), totalTokens: $0 * 1000, costUSD: nil) }

        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(CcusageDailyUsage(daily: daily), to: &lines, note: "n")

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.first?.label, "5/10", "oldest nine days are dropped")
        XCTAssertEqual(points.last?.label, "6/9", "most recent day is kept")
    }

    func testTrendAggregatesDuplicateDaysAndParsesCompactDates() {
        // Two source rows that normalize to the same calendar day (8-digit + hyphenated) collapse into
        // one bar carrying their summed tokens, not two bars splitting it.
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(
            CcusageDailyUsage(daily: [
                CcusageDay(date: "20260620", totalTokens: 1000, costUSD: nil),
                CcusageDay(date: "2026-06-20", totalTokens: 500, costUSD: nil)
            ]),
            to: &lines, note: "n"
        )

        guard case .chart(_, let points, _) = lines.first else { return XCTFail("expected a chart line") }
        XCTAssertEqual(points.count, 1, "same calendar day collapses to one bar")
        XCTAssertEqual(points.first?.label, "6/20")
        XCTAssertEqual(points.first?.value, 1500, "the day's tokens are summed, not split across bars")
    }

    func testAppendUsageTrendSkippedWhenNoUsableDays() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendUsageTrend(CcusageDailyUsage(daily: []), to: &lines, note: "n")
        XCTAssertTrue(lines.isEmpty, "no days means no chart, not an empty axis")
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
        // The placed tile with no `.chart` line must NOT leak the descriptor's gallery sample bars onto
        // the dashboard — it falls back to the no-data state.
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
        let store = makeDataStore(provider: provider, descriptor: descriptor)

        let data = store.data(for: descriptor)
        XCTAssertFalse(data.hasData)
    }

    // MARK: - Hover coordinator (TrendHoverState)

    func testHoverStateOpensThenClosesAroundBothRegions() async {
        let state = TrendHoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        XCTAssertFalse(state.isPresented)

        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "opens after the reveal dwell while the row is hovered")

        // Cursor crosses from the row into the popover: the row exits and the popover enters within grace.
        state.inlineHover(false)
        state.detailHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "stays open while the cursor is inside the popover")

        state.detailHover(false)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented, "closes once the cursor has left both the row and the popover")
    }

    func testHoverStateQuickPassDoesNotOpen() async {
        let state = TrendHoverState(revealDelay: .milliseconds(60), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        state.inlineHover(false)   // left before the reveal dwell elapsed
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.isPresented, "a quick pass over the row never opens the popover")
    }

    func testHoverStateDismissForcesClosed() async {
        let state = TrendHoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented)

        state.dismiss()
        XCTAssertFalse(state.isPresented, "teardown closes it immediately")
    }

    // MARK: - Helpers

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
