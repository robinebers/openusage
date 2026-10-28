import XCTest
@testable import OpenUsage

/// Covers the global meter-style setting: one switch (`WidgetDataStore.meterStyle`) flips every bounded
/// tile between "used" and "left/remaining", overrides any per-descriptor sample mode, leaves unbounded
/// tiles untouched, and persists across launches.
@MainActor
final class WidgetMeterStyleTests: XCTestCase {
    func testMeterStyleFlipsEveryBoundedFormat() async {
        let cases: [(name: String, format: ProgressFormat, used: Double, limit: Double, remaining: String, consumed: String)] = [
            ("percent", .percent, 80, 100, "20%", "80%"),
            ("dollars", .dollars, 80, 100, "$20", "$80"),
            ("count", .count(suffix: "credits"), 320, 1_000, "680", "320")
        ]

        for item in cases {
            let (store, descriptor) = await makeRefreshedStore(
                format: item.format, used: item.used, limit: item.limit
            )

            let remaining = store.data(for: descriptor)
            XCTAssertEqual(remaining.valueText, item.remaining, item.name)
            XCTAssertEqual(barValue(remaining.dashboardRow()), item.remaining, item.name)
            XCTAssertEqual(remaining.fraction, 1 - item.used / item.limit, accuracy: 0.0001, item.name)

            store.meterStyle = .used
            let used = store.data(for: descriptor)
            XCTAssertEqual(used.valueText, item.consumed, item.name)
            XCTAssertEqual(barValue(used.dashboardRow()), item.consumed, item.name)
            XCTAssertEqual(used.fraction, item.used / item.limit, accuracy: 0.0001, item.name)
        }
    }

    func testGlobalModeOverridesDescriptorSampleDisplayMode() async {
        // The descriptor sample is hardcoded to `.used`; the global store value must win on both the
        // live-data path (resolve) and the fallback (sample) path.
        let (store, descriptor) = await makeRefreshedStore(
            format: .percent,
            used: 80,
            limit: 100,
            sampleDisplayMode: .used
        )

        XCTAssertEqual(store.meterStyle, .remaining)
        XCTAssertEqual(store.data(for: descriptor).displayMode, .remaining)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: descriptor).displayMode, .used)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testFallbackSampleShowsNoDataRegardlessOfMode() {
        // No refresh => `data(for:)` returns the descriptor template flagged `hasData == false`. The row
        // and menu bar must show the no-data marker, never the template's placeholder
        // number — and flipping the global meter style can't resurrect a value that isn't there.
        let (store, descriptor) = makeStore(
            format: .percent,
            used: 80,
            limit: 100,
            sampleDisplayMode: .used
        )

        XCTAssertFalse(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.data(for: descriptor).valueText, WidgetData.noDataValue)

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: descriptor).valueText, WidgetData.noDataValue)
    }

    func testUnboundedTileIdenticalUnderBothModes() async {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.today",
            providerID: provider.id,
            metricLabel: "Today",
            sample: WidgetData(
                title: "Today",
                kind: .dollars,
                used: 0,
                limit: nil
            )
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Today", values: [
                    MetricValue(number: 42.50, kind: .dollars)
                ])]
            )
        )
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        store.meterStyle = .used
        let used = store.data(for: descriptor)

        XCTAssertEqual(remaining.valueText, "$42.50")
        XCTAssertEqual(remaining.dashboardRow().mark, .value("$42.50"))
        XCTAssertEqual(used.valueText, remaining.valueText)
        XCTAssertEqual(used.dashboardRow(), remaining.dashboardRow())
        XCTAssertEqual(used.displayedValue, remaining.displayedValue)
    }

    func testMeterStyleDefaultsToRemainingWithEmptySuite() {
        let store = makeEmptyStore(isolatedDefaults())
        XCTAssertEqual(store.meterStyle, .remaining)
    }

    func testMeterStylePersistsAcrossStoreInstances() {
        let defaults = isolatedDefaults()

        let store = makeEmptyStore(defaults)
        XCTAssertEqual(store.meterStyle, .remaining)

        store.meterStyle = .used // triggers didSet -> persists

        let reloaded = makeEmptyStore(defaults)
        XCTAssertEqual(reloaded.meterStyle, .used)
    }

    // MARK: - Helpers

    /// The value column of a bar row, `nil` for a value row.
    private func barValue(_ row: DashboardRowModel) -> String? {
        guard case .bar(_, _, let value, _, _) = row.mark else { return nil }
        return value
    }

    private func makeRefreshedStore(
        format: ProgressFormat,
        used: Double,
        limit: Double,
        sampleDisplayMode: WidgetDisplayMode = .used
    ) async -> (WidgetDataStore, WidgetDescriptor) {
        let (store, descriptor) = makeStore(
            format: format,
            used: used,
            limit: limit,
            sampleDisplayMode: sampleDisplayMode
        )
        await store.refreshAll()
        return (store, descriptor)
    }

    private func makeStore(
        format: ProgressFormat,
        used: Double,
        limit: Double,
        sampleDisplayMode: WidgetDisplayMode = .used
    ) -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.metric",
            providerID: provider.id,
            metricLabel: "Metric",
            sample: WidgetData(
                title: "Metric",
                kind: format.metricKind,
                used: used,
                limit: limit,
                displayMode: sampleDisplayMode
            )
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Metric", used: used, limit: limit, format: format)]
            )
        )
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        return (store, descriptor)
    }

    private func makeEmptyStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore.forTesting(
            [],
            defaults: defaults
        )
    }


}
