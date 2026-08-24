import XCTest
@testable import OpenUsage

/// Covers the global meter-style setting: one switch (`WidgetDataStore.meterStyle`) flips every bounded
/// tile between "used" and "left/remaining", overrides any per-descriptor sample mode, leaves unbounded
/// tiles untouched, and persists across launches.
@MainActor
final class WidgetMeterStyleTests: XCTestCase {
    func testMeterStyleFlipsEveryBoundedFormat() async {
        let cases: [(name: String, format: ProgressFormat, used: Double, limit: Double,
                     remaining: String, consumed: String, subtitle: String?)] = [
            ("percent", .percent, 80, 100, "20%", "80%", nil),
            ("dollars", .dollars, 80, 100, "$20.00", "$80.00", "$100 limit"),
            ("count", .count(suffix: "credits"), 320, 1_000, "680", "320", "credits")
        ]

        for item in cases {
            let (store, descriptor) = await makeRefreshedStore(
                format: item.format, used: item.used, limit: item.limit, suite: item.name
            )

            let remaining = store.data(for: descriptor)
            XCTAssertEqual(remaining.valueText, item.remaining, item.name)
            XCTAssertEqual(remaining.boundedHeadline, "\(item.remaining) left", item.name)
            XCTAssertEqual(remaining.boundedSubtitle, item.subtitle, item.name)
            XCTAssertEqual(remaining.fraction, 1 - item.used / item.limit, accuracy: 0.0001, item.name)

            store.meterStyle = .used
            let used = store.data(for: descriptor)
            XCTAssertEqual(used.valueText, item.consumed, item.name)
            XCTAssertEqual(used.boundedHeadline, "\(item.consumed) used", item.name)
            XCTAssertEqual(used.boundedSubtitle, item.subtitle, item.name)
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
