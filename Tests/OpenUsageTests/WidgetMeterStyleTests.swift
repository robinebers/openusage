import XCTest
@testable import OpenUsage

/// Covers the global meter-style setting: one switch (`WidgetDataStore.meterStyle`) flips every bounded
/// tile between "used" and "left/remaining", overrides any per-descriptor sample mode, leaves unbounded
/// tiles untouched, and persists across launches.
@MainActor
final class WidgetMeterStyleTests: XCTestCase {
    func testMeterStyleFlipsBoundedPercentTile() async {
        let (store, descriptor) = await makeRefreshedStore(
            format: .percent,
            used: 80,
            limit: 100,
            suite: "percent"
        )

        XCTAssertEqual(store.meterStyle, .remaining) // empty suite default
        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.valueText, "20%")
        XCTAssertEqual(remaining.boundedHeadline, "20% left")
        XCTAssertNil(remaining.boundedSubtitle)
        XCTAssertEqual(remaining.fraction, 0.20, accuracy: 0.0001)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.valueText, "80%")
        XCTAssertEqual(used.boundedHeadline, "80% used")
        XCTAssertNil(used.boundedSubtitle)
        XCTAssertEqual(used.fraction, 0.80, accuracy: 0.0001)
    }

    func testMeterStyleFlipsBoundedDollarsTile() async {
        let (store, descriptor) = await makeRefreshedStore(
            format: .dollars,
            used: 80,
            limit: 100,
            suite: "dollars"
        )

        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.valueText, "$20.00")
        XCTAssertEqual(remaining.boundedHeadline, "$20.00 left")
        XCTAssertEqual(remaining.boundedSubtitle, "$100 limit")
        XCTAssertEqual(remaining.fraction, 0.20, accuracy: 0.0001)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.valueText, "$80.00")
        XCTAssertEqual(used.boundedHeadline, "$80.00 used")
        XCTAssertEqual(used.boundedSubtitle, "$100 limit")
        XCTAssertEqual(used.fraction, 0.80, accuracy: 0.0001)
    }

    func testMeterStyleFlipsBoundedCountTile() async {
        let (store, descriptor) = await makeRefreshedStore(
            format: .count(suffix: "credits"),
            used: 320,
            limit: 1000,
            suite: "count"
        )

        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.valueText, "680")
        XCTAssertEqual(remaining.boundedHeadline, "680 left")
        XCTAssertEqual(remaining.boundedSubtitle, "credits")
        XCTAssertEqual(remaining.fraction, 0.68, accuracy: 0.0001)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.valueText, "320")
        XCTAssertEqual(used.boundedHeadline, "320 used")
        XCTAssertEqual(used.boundedSubtitle, "credits")
        XCTAssertEqual(used.fraction, 0.32, accuracy: 0.0001)
    }

    func testBoundedHeadlineWordFlipsSymmetricallyWithMeterStyle() async {
        // The same tile must carry the mode word in BOTH modes (regression: "Used" mode had dropped it).
        let (store, descriptor) = await makeRefreshedStore(
            format: .percent,
            used: 80,
            limit: 100,
            suite: "symmetry"
        )

        store.meterStyle = .remaining
        XCTAssertEqual(store.data(for: descriptor).boundedHeadline, "20% left")

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: descriptor).boundedHeadline, "80% used")
    }

    func testGlobalModeOverridesDescriptorSampleDisplayMode() async {
        // The descriptor sample is hardcoded to `.used`; the global store value must win on both the
        // live-data path (resolve) and the fallback (sample) path.
        let (store, descriptor) = await makeRefreshedStore(
            format: .percent,
            used: 80,
            limit: 100,
            sampleDisplayMode: .used,
            suite: "override"
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
            sampleDisplayMode: .used,
            suite: "fallback"
        )

        XCTAssertFalse(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.data(for: descriptor).valueText, WidgetData.noDataHeadline)

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: descriptor).valueText, WidgetData.noDataHeadline)
    }

    func testUnboundedTileIdenticalUnderBothModes() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.today",
            providerID: provider.id,
            metricLabel: "Today",
            sample: WidgetData(
                title: "Today",
                icon: provider.icon,
                kind: .dollars,
                used: 0,
                limit: nil,
                subtitleOverride: "on-device estimate"
            )
        )
        let runtime = TestProviderRuntime(
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
        let isolated = makeUserDefaults("unbounded")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: makeCache(isolated),
            defaults: isolated
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        store.meterStyle = .used
        let used = store.data(for: descriptor)

        XCTAssertEqual(remaining.valueText, "$42.50")
        XCTAssertEqual(remaining.unboundedSubtitle, "on-device estimate")
        XCTAssertEqual(used.valueText, remaining.valueText)
        XCTAssertEqual(used.unboundedSubtitle, remaining.unboundedSubtitle)
        XCTAssertEqual(used.displayedValue, remaining.displayedValue)
    }

    func testMeterStyleDefaultsToRemainingWithEmptySuite() {
        let store = makeEmptyStore(makeUserDefaults("default"))
        XCTAssertEqual(store.meterStyle, .remaining)
    }

    func testMeterStylePersistsAcrossStoreInstances() {
        let suiteName = "OpenUsageTests.MeterStyle.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = makeEmptyStore(defaults)
        XCTAssertEqual(store.meterStyle, .remaining)

        store.meterStyle = .used // triggers didSet -> persists

        let reloaded = makeEmptyStore(defaults)
        XCTAssertEqual(reloaded.meterStyle, .used)
    }

    // MARK: - Helpers

    private func makeRefreshedStore(
        format: ProgressFormat,
        used: Double,
        limit: Double,
        sampleDisplayMode: WidgetDisplayMode = .used,
        suite: String
    ) async -> (WidgetDataStore, WidgetDescriptor) {
        let (store, descriptor) = makeStore(
            format: format,
            used: used,
            limit: limit,
            sampleDisplayMode: sampleDisplayMode,
            suite: suite
        )
        await store.refreshAll()
        return (store, descriptor)
    }

    private func makeStore(
        format: ProgressFormat,
        used: Double,
        limit: Double,
        sampleDisplayMode: WidgetDisplayMode = .used,
        suite: String
    ) -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.metric",
            providerID: provider.id,
            metricLabel: "Metric",
            sample: WidgetData(
                title: "Metric",
                icon: provider.icon,
                kind: format.metricKind,
                used: used,
                limit: limit,
                countSuffix: format.countSuffix,
                displayMode: sampleDisplayMode
            )
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Metric", used: used, limit: limit, format: format)]
            )
        )
        let isolated = makeUserDefaults(suite)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: makeCache(isolated),
            defaults: isolated
        )
        return (store, descriptor)
    }

    private func makeEmptyStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: makeCache(defaults),
            defaults: defaults
        )
    }

    private func makeCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.MeterStyle.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
