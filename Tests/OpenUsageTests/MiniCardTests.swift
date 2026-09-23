import XCTest
@testable import OpenUsage

/// Mini cards: which metrics a collapsed provider header can miniaturize, and the per-provider
/// collapsed state behind the Enable Mini Cards setting.
@MainActor
final class MiniCardTests: XCTestCase {

    // MARK: - MiniMeter derivation

    func testBoundedRowBecomesAMeterCarryingTheRowsOwnNumbers() {
        let meter = MiniMeter(id: "claude.weekly", data: percentRow("Weekly", used: 57))

        XCTAssertEqual(meter?.id, "claude.weekly")
        XCTAssertEqual(meter?.title, "Weekly")
        XCTAssertEqual(meter?.fraction ?? 0, 0.57, accuracy: 0.0001)
        XCTAssertEqual(meter?.percentText, "57%")
    }

    func testPercentTextRoundsTheSameWayTheBarFills() {
        // `fraction` is built from the rounded display value, so the number and the bar can never
        // disagree. A row reading "8%" must not draw a 7.6% bar.
        let meter = MiniMeter(id: "claude.session", data: percentRow("Session", used: 7.6))

        XCTAssertEqual(meter?.percentText, "8%")
        XCTAssertEqual(meter?.fraction ?? 0, 0.08, accuracy: 0.0001)
    }

    func testUnboundedRowHasNoMeterToMiniaturize() {
        // A spend tile has no limit to fill against, so there is no bar to shrink.
        var row = WidgetData(title: "Today", icon: .providerMark("claude"), kind: .dollars, used: 12.5, limit: nil)
        row.hasData = true

        XCTAssertNil(MiniMeter(id: "claude.today", data: row))
    }

    func testRowWithoutDataHasNoMeter() {
        var row = percentRow("Extra Usage", used: 0)
        row.hasData = false

        XCTAssertNil(MiniMeter(id: "claude.extra", data: row))
    }

    func testSparklineRowHasNoMeter() {
        // Usage Trend is a day-by-day chart; it has no single value to reduce to one percentage.
        var row = percentRow("Usage Trend", used: 40)
        row.isChart = true

        XCTAssertNil(MiniMeter(id: "claude.trend", data: row))
    }

    func testMetersKeepCardOrderAndDropTheMeterlessRowsBetweenThem() {
        var spend = WidgetData(title: "Today", icon: .providerMark("claude"), kind: .dollars, used: 3, limit: nil)
        spend.hasData = true

        let meters = MiniMeter.meters(from: [
            (id: "claude.session", data: percentRow("Session", used: 8)),
            (id: "claude.today", data: spend),
            (id: "claude.weekly", data: percentRow("Weekly", used: 30))
        ])

        XCTAssertEqual(meters.map(\.id), ["claude.session", "claude.weekly"])
        XCTAssertEqual(meters.map(\.percentText), ["8%", "30%"])
    }

    func testMetersStopAtTheThreeBarLimit() {
        let rows = (1...5).map { index in
            (id: "claude.metric\(index)", data: percentRow("Metric \(index)", used: Double(index * 10)))
        }

        let meters = MiniMeter.meters(from: rows)

        XCTAssertEqual(meters.count, MiniMeter.limit)
        XCTAssertEqual(meters.map(\.id), ["claude.metric1", "claude.metric2", "claude.metric3"])
    }

    func testEmptyRowsProduceNoMeters() {
        XCTAssertTrue(MiniMeter.meters(from: []).isEmpty)
    }

    // MARK: - Collapsed-provider state

    func testProviderStartsExpandedAndTogglesToMinimized() {
        let store = makeStore("Toggle")

        XCTAssertFalse(store.isProviderMinimized("claude"))
        XCTAssertTrue(store.setProviderMinimized(true, for: "claude"))
        XCTAssertTrue(store.isProviderMinimized("claude"))
        XCTAssertFalse(store.isProviderMinimized("codex"))
    }

    func testSettingTheSameStateAgainReportsNoChange() {
        let store = makeStore("NoChange")
        store.setProviderMinimized(true, for: "claude")

        XCTAssertFalse(store.setProviderMinimized(true, for: "claude"))
        XCTAssertTrue(store.isProviderMinimized("claude"))
    }

    func testUnknownProviderIsIgnored() {
        let store = makeStore("Unknown")

        XCTAssertFalse(store.setProviderMinimized(true, for: "not-a-provider"))
        XCTAssertTrue(store.miniCardProviderIDs.isEmpty)
    }

    func testCollapsedProvidersSurviveARelaunch() {
        let suite = suiteName("Relaunch")
        let defaults = makeDefaults(suite)
        let first = makeStore(defaults: defaults)
        first.setProviderMinimized(true, for: "codex")

        // A second store over the same defaults is what the next launch sees.
        let second = makeStore(defaults: defaults)

        XCTAssertTrue(second.isProviderMinimized("codex"))
        XCTAssertFalse(second.isProviderMinimized("claude"))
    }

    func testExpandingAgainIsPersistedToo() {
        let suite = suiteName("Expand")
        let defaults = makeDefaults(suite)
        let first = makeStore(defaults: defaults)
        first.setProviderMinimized(true, for: "codex")
        first.setProviderMinimized(false, for: "codex")

        XCTAssertFalse(makeStore(defaults: defaults).isProviderMinimized("codex"))
    }

    func testCollapsedStateIsIndependentOfTheCaret() {
        // The caret says what an open card shows; a mini card says whether the card shows at all.
        // Collapsing must not disturb the caret, so expanding again restores the card as it was.
        let store = makeStore("Caret")
        store.setProviderExpanded(true, for: "claude")

        store.setProviderMinimized(true, for: "claude")

        XCTAssertTrue(store.isProviderExpanded("claude"))
        XCTAssertTrue(store.isProviderMinimized("claude"))
    }

    func testResetProviderRestoresItsFullCard() {
        let store = makeStore("ResetOne")
        store.setProviderMinimized(true, for: "claude")
        store.setProviderMinimized(true, for: "codex")

        store.resetProvider("claude")

        XCTAssertFalse(store.isProviderMinimized("claude"))
        XCTAssertTrue(store.isProviderMinimized("codex"))
    }

    func testResetToDefaultRestoresEveryCard() {
        let store = makeStore("ResetAll")
        store.setProviderMinimized(true, for: "claude")
        store.setProviderMinimized(true, for: "codex")

        store.resetToDefault()

        XCTAssertTrue(store.miniCardProviderIDs.isEmpty)
    }

    func testStoredCollapsedProviderThatNoLongerExistsIsDropped() {
        let suite = suiteName("StaleID")
        let defaults = makeDefaults(suite)
        defaults.set(["claude", "retired-provider"], forKey: "layout.miniCardProviders")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.miniCardProviderIDs, ["claude"])
    }

    // MARK: - Settings

    func testStyleDefaultsToSingleRowAndOffersBothLayouts() {
        XCTAssertEqual(MiniCardStyle.fallback, .singleRow)
        XCTAssertEqual(MiniCardStyle.allCases.map(\.label), ["Single Row", "Detailed"])
    }

    func testMiniCardsAreOffUntilTheUserTurnsThemOn() {
        XCTAssertFalse(MiniCardSetting.fallback)
    }

    // MARK: - Helpers

    private func percentRow(_ title: String, used: Double) -> WidgetData {
        WidgetData(title: title, icon: .providerMark("claude"), kind: .percent, used: used, limit: 100)
    }

    private func suiteName(_ name: String) -> String {
        "OpenUsageTests.MiniCard.\(name).\(UUID().uuidString)"
    }

    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(_ name: String) -> LayoutStore {
        makeStore(defaults: makeDefaults(suiteName(name)))
    }

    private func makeStore(defaults: UserDefaults) -> LayoutStore {
        LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly", "codex.session"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "codex.session"],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )
    }
}
