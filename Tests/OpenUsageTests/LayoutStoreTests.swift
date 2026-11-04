import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testUndoWalksBackMultipleSteps() {
        let store = makeStore()
        let metricsBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)
        let providersBefore = store.orderedProviders().map(\.id)
        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.session", in: "claude"))
        let metricsAfter = store.orderedSupportedMetrics(for: "claude").map(\.id)
        XCTAssertNotEqual(metricsAfter, metricsBefore)
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertNotEqual(store.orderedProviders().map(\.id), providersBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedProviders().map(\.id), providersBefore)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), metricsAfter)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), metricsBefore)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testAnAccountChangeThatKeepsEveryCardKeepsUndo() {
        let store = makeStore()
        let orderBefore = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        XCTAssertTrue(store.reorderMetric(dragged: "cursor.today", target: "cursor.usage", in: "cursor"))

        store.apply(registry: store.registry)

        XCTAssertTrue(store.undo(), "renaming an account keeps the layout's undo history")
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), orderBefore)
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore()
        for _ in 0..<(LayoutStore.maxUndoDepth + 10) {
            XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))
        }
        var steps = 0
        while store.undo() { steps += 1 }
        XCTAssertEqual(steps, LayoutStore.maxUndoDepth)
    }

    func testNoOpActionDoesNotRecordUndoStep() {
        let store = makeStore()
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testFreshCustomizeOrderFollowsProviderDeclarations() {
        let accounts = ProviderKind.allCases.enumerated().map { index, kind in
            Account(kind: kind, label: kind.displayName, addedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let providers = ProviderCatalog.make(accounts: accounts, vault: InMemoryCredentialVault())
        let store = makeStore(registry: .from(providers))

        for provider in providers {
            XCTAssertEqual(
                store.orderedSupportedMetrics(for: provider.provider.id).map(\.id),
                provider.widgetDescriptors.map(\.id),
                provider.provider.id
            )
        }
    }

    private func makeStore(_ defaults: UserDefaults? = nil, registry: WidgetRegistry = .mock) -> LayoutStore {
        LayoutStore(registry: registry, defaults: defaults ?? isolatedDefaults())
    }
}
