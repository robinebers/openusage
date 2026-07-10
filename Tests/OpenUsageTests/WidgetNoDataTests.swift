import XCTest
@testable import OpenUsage

/// Covers the "No data" state: a placed tile whose provider snapshot has no line matching the
/// descriptor's metric label must report `hasData == false`, render the exact "—"/"No data" copy,
/// and never leak its placeholder sample numbers into the menu bar.
@MainActor
final class WidgetNoDataTests: XCTestCase {
    func testDataForFlagsMissingLineAsNoData() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "missing-line")

        XCTAssertTrue(store.data(for: present).hasData)
        XCTAssertFalse(store.data(for: missing).hasData)
    }

    func testNoDataHeadlineAndTrailingCopy() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "copy")

        let blank = store.data(for: missing)
        XCTAssertFalse(blank.hasData)
        XCTAssertEqual(blank.headline, "—")
        XCTAssertEqual(blank.boundedTrailingText(), "No data")

        let real = store.data(for: present)
        XCTAssertTrue(real.hasData)
        XCTAssertNotEqual(real.headline, "—")
        XCTAssertNotEqual(real.boundedTrailingText(), "No data")
    }

    func testValueTextHidesPlaceholderWhenNoData() async {
        // The menu bar reads `valueText`; a missing line must never leak the descriptor's placeholder
        // template numbers there, so `valueText` reports the no-data marker just like the dashboard row.
        let (store, present, missing) = await makeRefreshedStore(suite: "valuetext")

        XCTAssertEqual(store.data(for: missing).valueText, WidgetData.noDataHeadline)
        XCTAssertNotEqual(store.data(for: present).valueText, WidgetData.noDataHeadline)
    }

    // Menu-bar ordering / no-data-skip / fallback are exercised on the real tray path
    // (MenuBarContentBuilder + LayoutStore.pinnedGroups) in MenuBarContentTests and MenuBarPinTests.

    // MARK: - Helpers

    private func makeRefreshedStore(
        suite: String
    ) async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
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
        let defaults = makeUserDefaults(suite)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [present, missing]),
            providers: [runtime],
            cache: makeCache(defaults),
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

    private func makeCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NoData.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
