import XCTest
@testable import OpenUsage

/// Covers the "No data" state: a placed tile whose provider snapshot has no line matching the
/// descriptor's metric label must report `hasData == false`, render the exact "—"/"No data" copy, and
/// never leak its placeholder sample numbers into the menu bar.
@MainActor
final class WidgetNoDataTests: XCTestCase {
    func testMissingLineShowsNoDataAcrossDashboardAndMenuBar() async {
        let (store, present, missing) = await makeRefreshedStore()

        let blank = store.data(for: missing)
        XCTAssertFalse(blank.hasData)
        XCTAssertEqual(blank.dashboardRow().mark, .value("No data"))
        XCTAssertEqual(blank.valueText, WidgetData.noDataValue)

        let real = store.data(for: present)
        XCTAssertTrue(real.hasData)
        XCTAssertEqual(real.dashboardRow().mark, .bar(fill: 0.6, severity: .normal, value: "60%", reset: nil))
        XCTAssertNotEqual(real.valueText, WidgetData.noDataValue)
    }

    // Menu-bar ordering / no-data-skip / fallback are exercised on the real tray path
    // (MenuBarContentBuilder + LayoutStore.pinnedGroups) in MenuBarContentTests and MenuBarPinTests.

    // MARK: - Helpers

    private func makeRefreshedStore() async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: "cursor")
        let present = boundedPercent(provider, id: "test.present", metric: "Present", sampleUsed: 40)
        // Deliberately fake sample numbers we must never show once the account lacks this metric.
        let missing = boundedPercent(provider, id: "test.missing", metric: "Missing", sampleUsed: 99)
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [present, missing],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Present", used: 40, limit: 100, format: .percent)]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
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
                kind: .percent,
                used: sampleUsed,
                limit: 100
            )
        )
    }

}
