import XCTest
@testable import OpenUsage

/// Regression for #703: a percent meter fed an out-of-range sample (a provider reporting a negative or
/// >100 utilization) must never surface "-5%" or "105%" on any rendering path — the tile headline, the
/// Used/Left flip tooltip, or the menu-bar value — in either meter style. The sample is sanitized at the
/// construction choke point (`WidgetDataStore.resolve`), with a defensive clamp in `MetricFormatter`.
@MainActor
final class WidgetPercentClampTests: XCTestCase {
    func testOutOfRangePercentSamplesClampAcrossEveryRenderingPath() async {
        for (suite, raw, clamped) in [("negative", -5.0, 0.0), ("over", 130.0, 100.0)] {
            let (store, descriptor) = await makePercentStore(used: raw, suite: suite)
            let usedText = "\(Int(clamped))%"
            let remainingText = "\(100 - Int(clamped))%"

            for (mode, value, word, opposite) in [
                (WidgetDisplayMode.remaining, remainingText, "left", "\(usedText) used"),
                (.used, usedText, "used", "\(remainingText) left")
            ] {
                store.meterStyle = mode
                let data = store.data(for: descriptor)
                XCTAssertEqual(data.used, clamped, suite)
                XCTAssertEqual(data.valueText, value, suite)
                XCTAssertEqual(data.boundedHeadline, "\(value) \(word)", suite)
                XCTAssertEqual(data.menuBarValue, value, suite)
                XCTAssertEqual(data.meterStyleTooltip, opposite, suite)
            }

            if clamped == 100 {
                XCTAssertEqual(store.data(for: descriptor).meterState(), .spent)
            }
        }
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
