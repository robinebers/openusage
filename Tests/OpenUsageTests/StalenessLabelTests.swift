import XCTest
@testable import OpenUsage

/// Regression coverage for #582: a refresh that keeps failing leaves the last good snapshot on screen
/// (stale-while-revalidate by design), but nothing told the user how old that data was — the fossilized
/// plan/limits looked current. The store now exposes a per-provider hint once the displayed snapshot ages
/// past its freshness window: a short "Outdated" label the dashboard header renders, plus a tooltip
/// ("Last updated 3h ago") that carries the precise age.
@MainActor
final class StalenessLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshSnapshotHasNoStalenessLabel() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now)
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testSnapshotWithinThresholdHasNoStalenessLabel() {
        // One refresh interval old is normal right before the next pass — must not flicker a hint on
        // healthy providers, so the threshold sits above a single interval.
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-RefreshSetting.interval))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testStaleSnapshotSurfacesOutdatedHint() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin"),
                       StalenessHint(label: "Outdated", tooltip: "Last updated 3h ago"))
    }

    func testSnapshotExactlyAtThresholdIsStale() {
        // Pins the `>=` boundary: exactly `stalenessThreshold` old must already count as stale.
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-WidgetDataStore.stalenessThreshold))
        XCTAssertNotNil(store.stalenessHint(for: "devin"))
    }

    func testSnapshotJustBelowThresholdIsNotStale() {
        // One second under the threshold must stay clean — locks the boundary against drift.
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-(WidgetDataStore.stalenessThreshold - 1)))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testVeryStaleSnapshotFormatsTooltipInDays() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 24 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin")?.tooltip, "Last updated 3d 0h ago")
    }

    func testFutureRefreshedAtHasNoStalenessLabel() {
        // Clock skew can stamp a snapshot in the future; a negative age must never render a hint.
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(60 * 60))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testMissingSnapshotHasNoStalenessLabel() {
        let store = makeStore()
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    /// The exact #582 scenario, end to end: a cached snapshot is on screen, the live refresh keeps
    /// failing, so the fossil persists — and is now labelled with its age instead of silently passing
    /// for current data.
    func testFailingRefreshKeepsFossilButLabelsItStale() async {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: .error(provider: provider, message: "Not logged in")
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
        // Old cached snapshot already on screen (the "Team 5x" fossil), three hours stale.
        store.snapshots["devin"] = ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-3 * 60 * 60)
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.plan(for: "devin"), "Team 5x", "stale-while-revalidate keeps the last good snapshot")
        XCTAssertNotNil(store.errorMessage(for: "devin"), "the failed refresh still raises the warning")
        XCTAssertEqual(store.stalenessHint(for: "devin"),
                       StalenessHint(label: "Outdated", tooltip: "Last updated 3h ago"),
                       "the fossil is now visibly labelled as old")
    }

    // MARK: - Helpers

    private func snapshot(refreshedAt: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )
    }

    private func makeStore() -> WidgetDataStore {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(provider: provider, descriptors: [descriptor],
                                          snapshot: snapshot(refreshedAt: now))
        return makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: some ProviderRuntime
    ) -> WidgetDataStore {
        let suiteName = "OpenUsageTests.Staleness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { self.now }),
            defaults: defaults,
            now: { self.now }
        )
    }
}
