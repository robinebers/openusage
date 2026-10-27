import XCTest
@testable import OpenUsage

/// Covers the per-provider failure backoff: a refresh that fails is negatively cached for one refresh
/// interval after a first failure, so the loop can't re-probe a broken provider before then. The normal
/// heartbeat and the manual `force` refresh still retry as expected. `RefreshBackoffTests` covers how
/// the wait grows and the provider-set waits.
@MainActor
final class FailureBackoffTests: XCTestCase {
    func testFailedProviderIsNotReprobedWithinBackoffWindow() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        // First wake probes and fails.
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertNotNil(store.errorMessage(for: runtime.provider.id))

        // Rapid subsequent wakes inside the backoff window must NOT re-probe.
        clock = clock.addingTimeInterval(5)
        await store.refreshAll()
        clock = clock.addingTimeInterval(5)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)

        // Once the window (one refresh interval after a first failure) elapses, the normal cadence retries.
        clock = clock.addingTimeInterval(RefreshSetting.failureBackoffBase)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testManualForceRefreshBypassesFailureBackoff() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)

        // ⌘R / footer refresh: the user just fixed auth and wants an immediate retry.
        clock = clock.addingTimeInterval(1)
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testSuccessClearsBackoffSoLaterWakesAreNotSuppressed() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        // The success snapshot is intentionally stale (an old `refreshedAt`), so the snapshot cache never
        // masks the behavior under test — whether pass 3 probes is then governed solely by the backoff.
        let okSnapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshots: [.error(provider: provider, message: "Not logged in"), okSnapshot]
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, clock: { clock })

        await store.refreshAll()                       // pass 1: fails → backoff until +5m
        XCTAssertEqual(runtime.refreshCount, 1)

        clock = clock.addingTimeInterval(1)
        await store.refreshAll(force: true)            // pass 2: forced success inside the window → clears backoff
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertNil(store.errorMessage(for: provider.id))

        // Pass 3 is still inside the original 5-minute window: had the success NOT cleared the backoff, this
        // would be suppressed (count stays 2). It probes, proving the backoff was cleared on recovery.
        clock = clock.addingTimeInterval(1)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 3)
    }

    // MARK: - Helpers

    private func makeFailingRuntime() -> StubRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: .error(provider: provider, message: "Not logged in")
        )
    }

    private func makeStore(
        runtime: some ProviderRuntime,
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        makeStore(provider: runtime.provider, descriptor: runtime.widgetDescriptors[0], runtime: runtime, clock: clock)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: some ProviderRuntime,
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        let suite = isolatedDefaults()
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: clock),
            defaults: suite,
            now: clock
        )
    }

}

// StubRuntime lives in TestSupport.swift.
