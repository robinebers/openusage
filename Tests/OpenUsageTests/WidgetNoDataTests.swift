import XCTest
@testable import OpenUsage

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

    private func makeRefreshedStore() async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
        let provider = Provider(id: "test", kind: .cursor)
        let present = boundedPercent(provider, key: "present", metric: "Present", sampleUsed: 40)
        let missing = boundedPercent(provider, key: "missing", metric: "Missing", sampleUsed: 99)
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
        key: String,
        metric: String,
        sampleUsed: Double
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider,
            key: key,
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
