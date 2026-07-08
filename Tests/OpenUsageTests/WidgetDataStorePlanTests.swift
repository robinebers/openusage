import XCTest
@testable import OpenUsage

/// Covers `WidgetDataStore.plan(for:)` and the Plan widget row: plan is `nil`
/// until the provider has a snapshot, then mirrors that snapshot's `plan`.
@MainActor
final class WidgetDataStorePlanTests: XCTestCase {
    func testPlanIsNilBeforeRefreshThenMirrorsSnapshot() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor(
            id: "claude.session",
            providerID: "claude",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 10, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                plan: "Max 20x",
                lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)]
            )
        )
        let defaults = makeDefaults("plan")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        XCTAssertNil(store.plan(for: "claude"))

        await store.refreshAll()

        XCTAssertEqual(store.plan(for: "claude"), "Max 20x")
        XCTAssertNil(store.plan(for: "unknown"))
    }

    func testPlanIsNilWhenSnapshotHasNoPlan() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "codex.session",
            providerID: "codex",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 50, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "codex",
                displayName: "Codex",
                lines: [.progress(label: "Session", used: 50, limit: 100, format: .percent)]
            )
        )
        let defaults = makeDefaults("no-plan")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll()

        XCTAssertNil(store.plan(for: "codex"))
    }

    func testPlanWidgetResolvesSnapshotPlan() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let planDescriptor = PlanWidget.descriptor(for: provider)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [planDescriptor],
            snapshot: ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                plan: "Team 5x",
                lines: []
            )
        )
        let defaults = makeDefaults("plan-widget")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [planDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        let before = store.data(for: planDescriptor)
        XCTAssertFalse(before.hasData)

        await store.refreshAll()

        let after = store.data(for: planDescriptor)
        XCTAssertTrue(after.hasData)
        XCTAssertEqual(after.unboundedDetail, "Team 5x")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        makeScratchDefaults(suiteName: "OpenUsageTests.Plan.\(name).\(UUID().uuidString)")
    }
}
