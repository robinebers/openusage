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

    func testSuccessfulRefreshWithoutHistoryPreservesOnlyLastGoodHistory() async throws {
        let provider = Self.testProvider
        let quota = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let historyDescriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "From test logs"
        )
        let trend = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: historyDescriptor.scope,
            estimatedCost: historyDescriptor.estimatedCost,
            sourceNote: historyDescriptor.sourceNote
        )
        let spend = WidgetDescriptor.spendTiles(provider: provider)
        let descriptors = [quota, trend] + spend
        let defaults = makeUserDefaults("history-scan-miss")
        let fixedNow = Date(timeIntervalSince1970: 1_752_364_800)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(
                    date: DailyUsageAccumulator.dayKey(from: fixedNow),
                    totalTokens: 400,
                    costUSD: 4
                )
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(
                    date: DailyUsageAccumulator.dayKey(from: fixedNow),
                    models: [ModelUsageEntry(model: "Test Model", totalTokens: 400, costUSD: 4)]
                )
            ])
        )
        var firstSnapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Original",
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
            refreshedAt: fixedNow,
            usageHistory: history
        )
        firstSnapshot = UsageHistorySnapshotRenderer.render(
            local: firstSnapshot,
            history: history,
            descriptor: historyDescriptor,
            now: fixedNow,
            combined: false
        )
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: firstSnapshot
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            now: { fixedNow }
        )

        await store.refreshAll(force: true)
        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Current",
            lines: [.progress(label: "Alpha", used: 60, limit: 100, format: .percent)],
            refreshedAt: fixedNow.addingTimeInterval(300)
        )
        await store.refreshAll(force: true)

        let refreshed = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(refreshed.plan, "Current")
        XCTAssertEqual(store.data(for: quota).used, 60)
        XCTAssertEqual(refreshed.usageHistory, history)
        guard case .values(_, _, _, _, _, let breakdown) = refreshed.line(label: "Today") else {
            return XCTFail("The retained history should rebuild the spend rows")
        }
        XCTAssertEqual(breakdown?.sourceNote, historyDescriptor.sourceNote)
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

    func testCancelledRefreshKeepsLastGoodHistoryAndSkipsPublication() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("cancelled-history")
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-17", totalTokens: 400, costUSD: 4)
            ])
        )
        let runtime = BlockingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                plan: "Last good",
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
                usageHistory: history
            )
        )
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )
        _ = await store.refresh(providerID: provider.id, force: true)
        var historyChangeCount = 0
        store.onLocalHistoryChanged = { historyChangeCount += 1 }

        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Partial cancelled result",
            lines: [.progress(label: "Alpha", used: 0, limit: 100, format: .percent)],
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        runtime.blockNextRefresh = true
        let task = Task {
            await store.refresh(providerID: provider.id, force: true)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !runtime.isWaiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard runtime.isWaiting else {
            runtime.resume()
            task.cancel()
            _ = await task.value
            return XCTFail("the provider refresh did not suspend before the timeout")
        }
        task.cancel()
        runtime.resume()

        let outcome = await task.value
        guard case .skipped = outcome else {
            return XCTFail("a canceled provider refresh must be skipped")
        }
        let retained = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(retained.plan, "Last good")
        XCTAssertEqual(retained.usageHistory, history)
        XCTAssertEqual(historyChangeCount, 0)
        XCTAssertFalse(store.refreshingProviderIDs.contains(provider.id))
        XCTAssertEqual(cache.loadSnapshots(providerIDs: [provider.id])[provider.id]?.plan, "Last good")
    }

    func testCompletedEmptyHistoryStillClearsLastGoodHistory() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("completed-empty-history")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                plan: "With history",
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
                usageHistory: ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2026-07-17", totalTokens: 400, costUSD: 4)
                    ])
                )
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        _ = await store.refresh(providerID: provider.id, force: true)

        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Completed empty scan",
            lines: [.progress(label: "Alpha", used: 50, limit: 100, format: .percent)],
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        _ = await store.refresh(providerID: provider.id, force: true)

        let refreshed = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(refreshed.plan, "Completed empty scan")
        XCTAssertEqual(refreshed.usageHistory?.series.daily, [])
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

@MainActor
private final class BlockingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot
    var blockNextRefresh = false
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        if blockNextRefresh {
            blockNextRefresh = false
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
            isWaiting = false
        }
        return snapshot
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
