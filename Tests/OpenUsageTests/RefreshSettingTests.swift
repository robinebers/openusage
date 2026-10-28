import XCTest
@testable import OpenUsage

/// Covers the refresh cadence as the single source of truth: `RefreshSetting`'s fixed interval, and the
/// store's freshness — a snapshot is fresh for one interval after it was fetched, across a
/// relaunch too, so a quick relaunch costs no requests and the first pass refetches only older ones.
@MainActor
final class RefreshSettingTests: XCTestCase {
    // MARK: - Fixed cadence

    func testCadenceIsFixedAtFiveMinutes() {
        XCTAssertEqual(RefreshSetting.interval, 300)
    }

    // MARK: - Freshness across a relaunch

    func testRelaunchWithinTheIntervalShowsTheSavedSnapshotWithoutRefetching() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = isolatedDefaults()

        // A prior session left a snapshot 4 minutes ago — inside the 5-minute interval.
        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 0, "a snapshot under 5 minutes old is fresh at launch")
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testRelaunchRefetchesASnapshotOlderThanTheInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = isolatedDefaults()
        storeSnapshot(used: 20, age: 301, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 20, limit: 100, format: .percent),
                       "the saved snapshot paints at launch")
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 80, limit: 100, format: .percent))
    }

    /// A snapshot from the future (a clock that moved back) is never fresh.
    func testASnapshotFromTheFutureIsRefetched() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = isolatedDefaults()
        storeSnapshot(used: 20, age: -60, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        await makeStore(runtime: runtime, suite: suite, now: now).refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
    }

    func testWithinSessionPassServedFromCacheUntilInterval() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = isolatedDefaults()

        // The snapshot was fetched 4 minutes ago, so it short-circuits the pass.
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots")
        cache.save(["test": ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-240)
        )])

        let runtime = makeRuntime(used: 80)
        let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: suite, now: { now })
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0) // fetched this session, within interval => no refetch
        XCTAssertNotNil(store.snapshots["test"])

        now = now.addingTimeInterval(61)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1, "the same-session cache expires after the refresh interval")
    }

    // MARK: - Helpers

    private func storeSnapshot(
        used: Double, age: TimeInterval, into suite: UserDefaults, now: Date
    ) {
        ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots").save(["test": ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        )])
    }

    private func makeRuntime(used: Double) -> StubRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: "test",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: used, limit: 100)
        )
        return StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "test",
                displayName: "Test",
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// A store launched at `now` over what `suite` saved: the relaunch case.
    private func makeStore(runtime: StubRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore.forTesting([runtime], defaults: suite, now: { now })
    }

}
