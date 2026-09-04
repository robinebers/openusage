import XCTest
@testable import OpenUsage

/// Covers the "No data" state: a placed tile whose provider snapshot has no line matching the
/// descriptor's metric label must report `hasData == false`, render the exact "—"/"No data" copy,
/// and never leak its placeholder sample numbers into the menu bar.
@MainActor
final class WidgetNoDataTests: XCTestCase {
    func testMissingLineShowsNoDataAcrossDashboardAndMenuBar() async {
        let (store, present, missing) = await makeRefreshedStore()

        let blank = store.data(for: missing)
        XCTAssertFalse(blank.hasData)
        XCTAssertEqual(blank.headline, "—")
        XCTAssertEqual(blank.boundedTrailingText(), "No data")
        XCTAssertEqual(blank.valueText, WidgetData.noDataHeadline)

        let real = store.data(for: present)
        XCTAssertTrue(real.hasData)
        XCTAssertNotEqual(real.headline, "—")
        XCTAssertNotEqual(real.boundedTrailingText(), "No data")
        XCTAssertNotEqual(real.valueText, WidgetData.noDataHeadline)
    }

    // Menu-bar ordering / no-data-skip / fallback are exercised on the real tray path
    // (MenuBarContentBuilder + LayoutStore.pinnedGroups) in MenuBarContentTests and MenuBarPinTests.

    // MARK: - Helpers

    private func makeRefreshedStore() async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))
        let present = boundedPercent(provider, id: "test.present", metric: "Present", sampleUsed: 40)
        // Deliberately fake sample numbers we must never show once the account lacks this metric.
        let missing = boundedPercent(provider, id: "test.missing", metric: "Missing", sampleUsed: 99)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [present, missing],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Present", used: 40, limit: 100, format: .percent)]
            )
        )
        let defaults = makeUserDefaults("missing-line")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [present, missing]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()
        return (store, present, missing)
    }

    private func boundedPercent(
        _ provider: Provider,
        id: String,
        metric: String,
        sampleUsed: Double
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metric,
            sample: WidgetData(
                title: metric,
                icon: provider.icon,
                kind: .percent,
                used: sampleUsed,
                limit: 100
            )
        )
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NoData.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
