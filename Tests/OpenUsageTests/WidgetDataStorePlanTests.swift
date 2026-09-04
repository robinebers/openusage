import XCTest
@testable import OpenUsage

/// Covers `WidgetDataStore.plan(for:)`: the provider-header plan is `nil` until the provider has a
/// snapshot, then mirrors that snapshot's `plan`.
@MainActor
final class WidgetDataStorePlanTests: XCTestCase {
    func testPlanMirrorsSnapshotAndHandlesMissingValues() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let cases: [(name: String, plan: String?)] = [("plan", "Max 20x"), ("no-plan", nil)]

        for item in cases {
            let runtime = TestProviderRuntime(
                provider: provider,
                descriptors: [],
                snapshot: ProviderSnapshot(
                    providerID: provider.id, displayName: provider.displayName, plan: item.plan, lines: []
                )
            )
            let defaults = makeDefaults(item.name)
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: []),
                providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
                defaults: defaults
            )

            XCTAssertNil(store.plan(for: provider.id))
            await store.refreshAll()
            XCTAssertEqual(store.plan(for: provider.id), item.plan)
            XCTAssertNil(store.plan(for: "unknown"))
        }
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Plan.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
