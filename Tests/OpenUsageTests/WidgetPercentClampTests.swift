import XCTest
@testable import OpenUsage

/// Regression for #703: a percent meter fed an out-of-range sample (a provider reporting a negative or
/// >100 utilization) must never surface "-5%" or "105%" on any rendering path — the tile headline, the
/// Used/Left flip tooltip, or the menu-bar value — in either meter style. The sample is sanitized at the
/// construction choke point (`WidgetDataStore.resolve`), with a defensive clamp in `MetricFormatter`.
@MainActor
final class WidgetPercentClampTests: XCTestCase {
    func testNegativePercentSampleNeverRendersNegative() async {
        let (store, descriptor) = await makePercentStore(used: -5, suite: "negative")

        // Default (remaining) mode: clamped used = 0 reads as a clean "0% used" / "100% left" meter.
        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.used, 0) // sanitized at construction
        XCTAssertEqual(remaining.valueText, "100%")
        XCTAssertEqual(remaining.boundedHeadline, "100% left")
        XCTAssertEqual(remaining.menuBarValue, "100%")
        // The flip tooltip was the path that leaked "-5% used" even in the default mode.
        XCTAssertEqual(remaining.meterStyleTooltip, "0% used")

        // Used mode: the headline itself was the visible "-5% used" bug.
        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.valueText, "0%")
        XCTAssertEqual(used.boundedHeadline, "0% used")
        XCTAssertEqual(used.menuBarValue, "0%")
        XCTAssertEqual(used.meterStyleTooltip, "100% left")
    }

    func testOverHundredPercentSampleNeverRendersOverHundred() async {
        let (store, descriptor) = await makePercentStore(used: 130, suite: "over")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.used, 100) // sanitized at construction
        XCTAssertEqual(used.valueText, "100%")
        XCTAssertEqual(used.boundedHeadline, "100% used")
        XCTAssertEqual(used.menuBarValue, "100%")
        // Overage still reads as spent — it's conveyed by the meter state, not an out-of-range number.
        XCTAssertEqual(used.meterState(), .spent)

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.valueText, "0%")
        XCTAssertEqual(remaining.boundedHeadline, "0% left")
        XCTAssertEqual(remaining.menuBarValue, "0%")
    }

    // MARK: - Helper

    /// A refreshed store whose single provider emits one `.progress(format: .percent)` line with the
    /// given `used` against a limit of 100 — i.e. the real resolve path every provider funnels through.
    private func makePercentStore(used: Double, suite: String) async -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.metric",
            providerID: provider.id,
            metricLabel: "Metric",
            sample: WidgetData(title: "Metric", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Metric", used: used, limit: 100, format: .percent)]
            )
        )
        let suiteName = "OpenUsageTests.PercentClamp.\(suite).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )
        await store.refreshAll()
        return (store, descriptor)
    }
}
