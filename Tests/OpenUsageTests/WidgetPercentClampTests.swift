import XCTest
@testable import OpenUsage

@MainActor
final class WidgetPercentClampTests: XCTestCase {
    func testOutOfRangePercentSamplesClampAcrossEveryRenderingPath() async {
        for (suite, raw, clamped) in [("negative", -5.0, 0.0), ("over", 130.0, 100.0)] {
            let (store, descriptor) = await makePercentStore(used: raw)
            let usedText = "\(Int(clamped))%"
            let remainingText = "\(100 - Int(clamped))%"

            for (mode, value) in [
                (WidgetDisplayMode.remaining, remainingText),
                (.used, usedText)
            ] {
                store.meterStyle = mode
                let data = store.data(for: descriptor)
                XCTAssertEqual(data.used, clamped, suite)
                XCTAssertEqual(data.valueText, value, suite)
                XCTAssertEqual(data.dashboardRow().mark, .bar(fill: mode == .remaining ? 1 - clamped / 100 : clamped / 100, severity: clamped == 100 ? .critical : .normal, value: value, reset: nil, isUsedUp: clamped == 100), suite)
                XCTAssertEqual(data.menuBarValue, value, suite)
            }
        }
    }

    private func makePercentStore(used: Double) async -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor.percent(key: "metric", provider: provider, title: "Metric")
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
