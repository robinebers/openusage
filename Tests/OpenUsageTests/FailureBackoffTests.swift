import XCTest
@testable import OpenUsage

/// Covers the per-provider failure backoff: a refresh that fails is negatively cached for a short
/// window, so an over-eager refresh loop (e.g. a wake burst) can't re-probe a broken provider — the
/// logged-out Devin/Grok case — in a tight subprocess/network loop. The normal heartbeat and the manual
/// `force` refresh still retry as expected.
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

        // Once the window elapses, the normal cadence retries.
        clock = clock.addingTimeInterval(60)
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
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        // The success snapshot is intentionally stale (an old `refreshedAt`), so the snapshot cache never
        // masks the behavior under test — whether pass 3 probes is then governed solely by the backoff.
        let okSnapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshots: [.error(provider: provider, message: "Not logged in"), okSnapshot]
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, clock: { clock })

        await store.refreshAll()                       // pass 1: fails → backoff until +60s
        XCTAssertEqual(runtime.refreshCount, 1)

        clock = clock.addingTimeInterval(1)
        await store.refreshAll(force: true)            // pass 2: forced success inside the window → clears backoff
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertNil(store.errorMessage(for: provider.id))

        // Pass 3 is still inside the original 60s window: had the success NOT cleared the backoff, this
        // would be suppressed (count stays 2). It probes, proving the backoff was cleared on recovery.
        clock = clock.addingTimeInterval(1)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 3)
    }

    func testClearingBackoffAllowsImmediateReprobe() async {
        // The re-enable path: clearing the backoff must let the very next pass probe, even inside the
        // window, so a just-re-enabled provider isn't stuck on stale data until the 5-minute heartbeat.
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()                       // fail → backoff
        XCTAssertEqual(runtime.refreshCount, 1)

        clock = clock.addingTimeInterval(5)
        await store.refreshAll()                       // inside window → suppressed
        XCTAssertEqual(runtime.refreshCount, 1)

        store.clearFailureBackoff(for: runtime.provider.id)
        await store.refreshAll()                       // backoff cleared → probes immediately
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    // MARK: - Helpers

    private func makeFailingRuntime() -> CountingProviderRuntime {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return CountingProviderRuntime(
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
        let suite = makeUserDefaults("backoff")
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: clock),
            defaults: suite,
            now: clock
        )
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Backoff.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Returns a different snapshot per call (then repeats the last), so a test can model a provider that
/// fails and later recovers — which `CountingProviderRuntime` (one fixed snapshot) can't express.
@MainActor
final class SequenceProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let snapshots: [ProviderSnapshot]
    private(set) var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshots: [ProviderSnapshot]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshots = snapshots
    }

    func refresh() async -> ProviderSnapshot {
        let snapshot = snapshots[min(refreshCount, snapshots.count - 1)]
        refreshCount += 1
        return snapshot
    }
}
