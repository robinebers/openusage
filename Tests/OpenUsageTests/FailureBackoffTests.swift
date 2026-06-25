import XCTest
@testable import OpenUsage

/// Covers the per-provider failure backoff: a refresh that fails is negatively cached until its next
/// scheduled retry, so an over-eager wake burst can't re-probe a broken provider in a tight loop. Manual
/// `force` refresh still retries immediately.
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

        // Once Devin's first failure window elapses, the normal cadence retries.
        clock = clock.addingTimeInterval(300)
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

        await store.refreshAll()                       // pass 1: fails -> backoff until +5m
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

    func testSuccessfulRefreshSchedulesProviderBaseCadence() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = makeRuntime(providerID: "codex", displayName: "Codex", used: 12, clock: clock)
        let claude = makeRuntime(providerID: "claude", displayName: "Claude", used: 34, clock: clock)
        let store = makeStore(runtimes: [codex, claude], clock: { clock })

        await store.refreshAll()

        XCTAssertEqual(store.nextProbeAtByProvider["codex"], clock.addingTimeInterval(60))
        XCTAssertEqual(store.nextProbeAtByProvider["claude"], clock.addingTimeInterval(180))
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(60))
    }

    func testCodexFailureBackoffSequenceCapsAtFifteenMinutes() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime(providerID: "codex", displayName: "Codex")
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(120))

        clock = clock.addingTimeInterval(120)
        await store.refreshAll()
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(300))

        clock = clock.addingTimeInterval(300)
        await store.refreshAll()
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(600))

        clock = clock.addingTimeInterval(600)
        await store.refreshAll()
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(900))

        clock = clock.addingTimeInterval(900)
        await store.refreshAll()
        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), clock.addingTimeInterval(900))
    }

    func testRetryAfterCanExtendFailureBackoff() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor(
            id: "claude.session", providerID: provider.id, metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let retryAfter = clock.addingTimeInterval(10 * 60)
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.badge(label: "Status", text: "Rate limited, retry in ~10m")],
                refreshedAt: clock,
                retryAfter: retryAfter
            )
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, clock: { clock })

        await store.refreshAll()

        XCTAssertEqual(store.nextScheduledRefreshDate(at: clock), retryAfter)
    }

    // MARK: - Helpers

    private func makeFailingRuntime(
        providerID: String = "devin",
        displayName: String = "Devin"
    ) -> CountingProviderRuntime {
        let provider = Provider(id: providerID, displayName: displayName, icon: .providerMark(providerID))
        let descriptor = WidgetDescriptor(
            id: "\(providerID).weekly", providerID: provider.id, metricLabel: "Weekly quota",
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

    private func makeStore(
        runtimes: [CountingProviderRuntime],
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        let suite = makeUserDefaults("schedule")
        return WidgetDataStore(
            registry: WidgetRegistry(
                providers: runtimes.map(\.provider),
                descriptors: runtimes.flatMap(\.widgetDescriptors)
            ),
            providers: runtimes.map { $0 as ProviderRuntime },
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: clock),
            defaults: suite,
            now: clock
        )
    }

    private func makeRuntime(
        providerID: String,
        displayName: String,
        used: Double,
        clock: Date
    ) -> CountingProviderRuntime {
        let provider = Provider(id: providerID, displayName: displayName, icon: .providerMark(providerID))
        let descriptor = WidgetDescriptor(
            id: "\(providerID).session", providerID: provider.id, metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: clock
            )
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
