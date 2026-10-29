import XCTest
@testable import OpenUsage

@MainActor
final class StalenessLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshSnapshotsAndFutureClockSkewHaveNoStalenessLabel() {
        for offset in [0, -RefreshSetting.interval, -(RefreshSetting.stalenessThreshold - 1), 3_600] {
            let store = makeStore()
            store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(offset))
            XCTAssertNil(store.stalenessHint(for: "devin"), "offset: \(offset)")
        }
    }

    func testStaleSnapshotSurfacesItsAge() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin"), "Last updated 3h ago")
    }

    func testSnapshotExactlyAtThresholdIsStale() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-RefreshSetting.stalenessThreshold))
        XCTAssertNotNil(store.stalenessHint(for: "devin"))
    }

    func testVeryStaleSnapshotFormatsTooltipInDays() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 24 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin"), "Last updated 3d 0h ago")
    }

    func testMissingSnapshotHasNoStalenessLabel() {
        let store = makeStore()
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testFailingRefreshKeepsFossilButLabelsItStale() async {
        let provider = Provider(id: "devin", kind: .claude)
        let descriptor = WidgetDescriptor(
            provider: provider, key: "weekly", metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            failure: RefreshFailure(message: "Not logged in", kind: .refused)
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
        store.snapshots["devin"] = ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-3 * 60 * 60)
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.plan(for: "devin"), "Team 5x", "stale-while-revalidate keeps the last good snapshot")
        XCTAssertNotNil(store.errorMessage(for: "devin"), "the failed refresh still raises the warning")
        XCTAssertEqual(store.stalenessHint(for: "devin"), "Last updated 3h ago",
                       "the fossil is now visibly labelled as old")
    }

    private func snapshot(refreshedAt: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )
    }

    private func makeStore() -> WidgetDataStore {
        let provider = Provider(id: "devin", kind: .claude)
        let descriptor = WidgetDescriptor(
            provider: provider, key: "weekly", metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
        )
        let runtime = StubRuntime(provider: provider, descriptors: [descriptor],
                                          snapshot: snapshot(refreshedAt: now))
        return makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: some ProviderRuntime
    ) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        return WidgetDataStore.forTesting([runtime], defaults: defaults, now: { self.now })
    }
}
