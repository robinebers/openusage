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

    func testFreshDefaultLayoutShowsEveryMetricForAccountCards() {
        let accounts = [Account(kind: .claude, label: "Work"), Account(kind: .codex, label: "Work")]
        let providers = ProviderCatalog.make(accounts: accounts, vault: InMemoryCredentialVault())
        let store = makeStore(registry: .from(providers))

        for account in accounts {
            XCTAssertTrue(store.visibleDescriptors.contains { $0.id == "\(account.cardID).session" })
            XCTAssertTrue(store.visibleDescriptors.contains { $0.id == "\(account.cardID).rateLimitResets" })
        }
    }

    func testMetricOrderPersists() throws {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults)
        let first = try XCTUnwrap(store.orderedSupportedMetrics(for: "claude").first?.id)

        XCTAssertTrue(store.reorderMetric(dragged: "claude.extra", target: first, in: "claude"))

        XCTAssertEqual(makeStore(defaults).orderedSupportedMetrics(for: "claude").first?.id, "claude.extra")
    }

    func testDisplayGroupsListEveryMetricInMetricOrder() {
        let store = makeStore()

        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.metrics.map(\.id), ["claude.weekly", "claude.session", "claude.extra", "claude.today"])
    }

    func testAccountListFollowsReorder() {
        let store = makeStore()
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertEqual(store.orderedProviders().map(\.id), ["cursor", "claude", "codex"])
        XCTAssertEqual(store.displayGroups.map(\.provider.id), ["cursor", "claude", "codex"])
    }

    func testCustomizeProviderIDClearsWhenLeavingAccounts() {
        let store = PopoverState()
        store.screen = .accounts
        store.customizeProviderID = "claude"
        XCTAssertEqual(store.customizeProviderID, "claude")

        store.screen = .dashboard
        XCTAssertNil(store.customizeProviderID, "leaving Accounts resets the L2 selection back to the list")

        store.screen = .accounts
        store.customizeProviderID = "codex"
        store.screen = .settings
        XCTAssertNil(store.customizeProviderID)
    }

    private func makeStore(_ defaults: UserDefaults? = nil, registry: WidgetRegistry = .mock) -> LayoutStore {
        LayoutStore(registry: registry, defaults: defaults ?? isolatedDefaults())
    }
}
