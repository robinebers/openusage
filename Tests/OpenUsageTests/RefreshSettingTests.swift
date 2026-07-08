import XCTest
@testable import OpenUsage

/// Covers the refresh cadence as the single source of truth: `RefreshSetting`'s fixed interval, and the
/// snapshot cache's session-scoped freshness — a snapshot is fresh for one interval only *within the
/// session that fetched it*, so a relaunch always refetches on the first pass (it still paints the cached
/// value instantly) while a within-session pass is served from cache until the interval elapses. See #697.
@MainActor
final class RefreshSettingTests: XCTestCase {
    // MARK: - Fixed cadence

    func testCadenceIsFixedAtFiveMinutes() {
        XCTAssertEqual(RefreshSetting.defaultMinutes, 5)
        XCTAssertEqual(RefreshSetting.interval, 300)
    }

    // MARK: - Session-scoped freshness

    func testRelaunchRefetchesEvenWithinIntervalButPaintsCachedValueFirst() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-within")

        // A prior session left a snapshot 4 minutes ago — inside the 5-minute interval.
        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        // A fresh store/cache (= relaunch) loads it from disk for instant paint…
        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))

        // …but a disk-loaded snapshot never gates the refresh, so the first pass refetches (#697) even
        // though the snapshot is still within the interval.
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 80, limit: 100, format: .percent))
    }

    func testWithinSessionPassServedFromCacheUntilInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("within-session")

        // One cache instance shared between the seeding write and the store models a single running
        // session: the snapshot was fetched 4 minutes ago *this* session, so it short-circuits the pass.
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-240)
        ))

        let runtime = makeRuntime(used: 80)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: cache,
            defaults: suite
        )
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0) // fetched this session, within interval => no refetch
        XCTAssertNotNil(store.snapshots["test"])
    }

    func testCacheExpiresPastInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-expired")

        // A prior session left a snapshot 6 minutes ago — older than the 5-minute interval.
        storeSnapshot(used: 20, age: 360, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1) // past interval => refetched
    }

    // MARK: - Helpers

    private func storeSnapshot(used: Double, age: TimeInterval, into suite: UserDefaults, now: Date) {
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        ))
    }

    private func makeRuntime(used: Double) -> CountingProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: "test",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: used, limit: 100)
        )
        return CountingProviderRuntime(
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

    /// Builds a store backed by a cache at the default (fixed) refresh-interval TTL — the relaunch case.
    private func makeStore(runtime: CountingProviderRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now }),
            defaults: suite
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        makeScratchDefaults(suiteName: "OpenUsageTests.RefreshSetting.\(name).\(UUID().uuidString)")
    }
}
