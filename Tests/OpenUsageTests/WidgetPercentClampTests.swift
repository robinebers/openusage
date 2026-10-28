import XCTest
@testable import OpenUsage

@MainActor
final class WidgetPercentClampTests: XCTestCase {
    func testOutOfRangePercentSamplesClampAcrossEveryRenderingPath() async {
        for (suite, raw, clamped) in [("negative", -5.0, 0.0), ("over", 130.0, 100.0)] {
            let (store, descriptor) = await makePercentStore(used: raw, suite: suite)
            let usedText = "\(Int(clamped))%"
            let remainingText = "\(100 - Int(clamped))%"

            for (mode, value, word) in [
                (WidgetDisplayMode.remaining, remainingText, "left"),
                (.used, usedText, "used")
            ] {
                store.meterStyle = mode
                let data = store.data(for: descriptor)
                XCTAssertEqual(data.used, clamped, suite)
                XCTAssertEqual(data.valueText, value, suite)
                XCTAssertEqual(data.dashboardRow().mark, .bar(fill: mode == .remaining ? 1 - clamped / 100 : clamped / 100, severity: clamped == 100 ? .critical : .normal, value: value, reset: nil), "\(suite) \(word)")
                XCTAssertEqual(data.menuBarValue, value, suite)
            }

            if clamped == 100 {
                XCTAssertEqual(store.data(for: descriptor).meterState(), .spent)
            }
        }
    }

    private func makePercentStore(used: Double, suite: String) async -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "metric",
            metricLabel: "Metric",
            sample: WidgetData(title: "Metric", kind: .percent, used: 0, limit: 100)
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Metric", used: used, limit: 100, format: .percent)]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()
        return (store, descriptor)
    }
}
