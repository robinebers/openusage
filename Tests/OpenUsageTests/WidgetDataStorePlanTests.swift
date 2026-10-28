import XCTest
@testable import OpenUsage

/// Covers `WidgetDataStore.plan(for:)`: the provider-header plan is `nil` until the provider has a
/// snapshot, then mirrors that snapshot's `plan`.
@MainActor
final class WidgetDataStorePlanTests: XCTestCase {
    func testPlanMirrorsSnapshotAndHandlesMissingValues() async {
        let provider = Provider(id: "claude", kind: .claude)
        let cases: [(name: String, plan: String?)] = [("plan", "Max 20x"), ("no-plan", nil)]

        for item in cases {
            let runtime = StubRuntime(
                provider: provider,
                descriptors: [],
                snapshot: ProviderSnapshot(
                    providerID: provider.id, displayName: provider.displayName, plan: item.plan, lines: []
                )
            )
            let defaults = isolatedDefaults()
            let store = WidgetDataStore.forTesting([runtime], defaults: defaults)

            XCTAssertNil(store.plan(for: provider.id))
            await store.refreshAll()
            XCTAssertEqual(store.plan(for: provider.id), item.plan)
            XCTAssertNil(store.plan(for: "unknown"))
        }
    }

}
