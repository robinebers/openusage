import Observation
import os
import XCTest
@testable import OpenUsage

/// Covers stale-while-revalidate display: expired cached snapshots still load at launch (so the menu
/// bar never blanks to "—" while the first refresh runs), and a failed refresh records a provider
/// error while keeping the last good snapshot on screen instead of collapsing rows to "No data".
@MainActor
final class StaleWhileRevalidateTests: XCTestCase {
    func testExpiredSnapshotStillLoadsAtLaunchThenRefreshes() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("stale-launch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        // Persist a snapshot that is well past the TTL (a relaunch hours later).
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSinceNow: -7200)
        ))

        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 55, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )

        // Stale values display immediately at launch…
        XCTAssertEqual(store.data(for: descriptor).used, 40)
        XCTAssertTrue(store.data(for: descriptor).hasData)

        // …but the expired cache does not short-circuit the refresh: the provider is hit and wins.
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).used, 55)
    }

    func testFailedRefreshKeepsLastGoodSnapshotAndRecordsError() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("error-keeps-stale")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll(force: true)
        XCTAssertTrue(store.data(for: descriptor).hasData)
        XCTAssertNil(store.errorMessage(for: provider.id))

        // The next refresh fails: the error surfaces, but the good data stays on screen.
        runtime.snapshot = ProviderSnapshot.error(provider: provider, message: "Not signed in")
        await store.refreshAll(force: true)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")
        XCTAssertTrue(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.data(for: descriptor).used, 40)

        // A later successful refresh clears the error again.
        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 60, limit: 100, format: .percent)]
        )
        await store.refreshAll(force: true)
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertEqual(store.data(for: descriptor).used, 60)
    }

    func testCacheHitRefreshDoesNotInvalidateSnapshotObservers() async {
        // Regression for #18: a cache-hit pass must not re-assign an unchanged snapshot.
        // `@Observable` doesn't compare values, so a no-op write would still re-render the
        // menu-bar label (and re-run its ImageRenderer) every pass.
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("cache-hit-no-invalidation")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        // A fresh (within-TTL) cached snapshot, also loaded into `snapshots` by the store's init.
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
        ))

        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 55, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )

        // Lock-boxed because `onChange` is `@Sendable`; it fires synchronously during the write
        // (if any), so reading it after the pass is deterministic.
        let snapshotsInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.snapshots
        } onChange: {
            snapshotsInvalidated.withLock { $0 = true }
        }

        await store.refreshAll()

        XCTAssertFalse(snapshotsInvalidated.withLock { $0 })
        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).used, 40)
    }

    func testErrorBeforeAnyDataShowsNoDataPlusError() async {
        // A provider that has never refreshed successfully has nothing to keep: rows are "No data"
        // and the error indicator explains why.
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("error-no-data")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot.error(provider: provider, message: "Not signed in")
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll(force: true)
        XCTAssertFalse(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")
    }

    // MARK: - Fixtures

    private static let testProvider = Provider(
        id: "test",
        displayName: "Test",
        icon: .providerMark("cursor")
    )

    private static func descriptor(_ provider: Provider, id: String, metric: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metric,
            sample: WidgetData(
                title: metric,
                icon: provider.icon,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

    func testCorruptCacheBlobRecoversToEmptyInsteadOfDroppingSilently() {
        // A non-decodable blob under the cache key (post-upgrade schema drift, a half-written
        // write, a manual `defaults` edit) must recover to an empty cache rather than crash — and,
        // per the loud-fail rule, leave a warn. Previously `try?` dropped ALL providers' snapshots
        // silently, which is the load-side feeder of the refresh storm.
        let defaults = makeUserDefaults("corrupt-cache")
        defaults.set(Data("not a valid snapshot payload".utf8), forKey: "snapshots")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        let loaded = cache.loadSnapshots(providerIDs: ["test.alpha"])

        XCTAssertTrue(loaded.isEmpty)
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.StaleWhileRevalidate.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Test runtime whose snapshot can be swapped between refresh passes.
@MainActor
private final class MutableProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        snapshot
    }
}
