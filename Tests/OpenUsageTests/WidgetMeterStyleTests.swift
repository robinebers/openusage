import XCTest
@testable import OpenUsage

@MainActor
final class WidgetMeterStyleTests: XCTestCase {
    func testMeterStyleFlipsEveryBoundedFormat() async {
        let cases: [(name: String, format: ProgressFormat, used: Double, limit: Double, remaining: String, consumed: String)] = [
            ("percent", .percent, 80, 100, "20%", "80%"),
            ("dollars", .dollars, 80, 100, "$20", "$80"),
            ("count", .count(suffix: "credits"), 320, 1_000, "680", "320")
        ]

        for item in cases {
            let (store, descriptor) = makeStore(
                format: item.format, used: item.used, limit: item.limit
            )
            await store.refreshAll()

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

    func testMeterStylePersistsAcrossStoreInstances() {
        let defaults = isolatedDefaults()

        let store = WidgetDataStore.forTesting([], defaults: defaults)
        XCTAssertEqual(store.meterStyle, .remaining)

        store.meterStyle = .used

        let reloaded = WidgetDataStore.forTesting([], defaults: defaults)
        XCTAssertEqual(reloaded.meterStyle, .used)
    }

    private func barValue(_ row: DashboardRowModel) -> String? {
        guard case .bar(_, _, let value, _, _) = row.mark else { return nil }
        return value
    }

    private func makeStore(
        format: ProgressFormat,
        used: Double,
        limit: Double
    ) -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "metric",
            metricLabel: "Metric",
            sample: WidgetData(
                title: "Metric",
                kind: format.metricKind,
                used: used,
                limit: limit
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
}
