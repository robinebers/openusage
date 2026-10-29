import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testUndoRestoresRemovedMetricToSamePosition() {
        let store = makeStore()
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)
        let enabledBefore = store.visibleDescriptors.map(\.id).filter { $0.hasPrefix("claude.") }

        store.setMetricEnabled("claude.weekly", false)
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)
        XCTAssertEqual(
            store.visibleDescriptors.map(\.id).filter { $0.hasPrefix("claude.") },
            enabledBefore
        )
    }

    func testUndoReversesEnable() {
        let store = makeStore()
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))

        store.setMetricEnabled("cursor.today", true)
        XCTAssertTrue(store.isMetricEnabled("cursor.today"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.today"), "undo turns an enabled metric back off")
        XCTAssertFalse(store.canUndo, "undo must not record itself")
    }

    func testShowMetricsTurnsHiddenMetricsBackOnAsOneUndoStep() {
        let store = makeStore()
        store.setMetricEnabled("claude.weekly", false)
        store.setMetricEnabled("claude.extra", false)

        store.showMetrics(["claude.weekly", "claude.extra"])
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isMetricEnabled("claude.extra"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"), "one undo hides both again")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
    }

    func testUndoReversesMetricReorder() {
        let store = makeStore()
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)

        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.session", in: "claude"))
        XCTAssertNotEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore,
                       "undo restores the exact prior metric order")
    }

    func testUndoReversesProviderReorder() {
        let store = makeStore()
        let orderBefore = store.orderedProviders().map(\.id)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertNotEqual(store.orderedProviders().map(\.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedProviders().map(\.id), orderBefore,
                       "undo restores the exact prior provider order")
    }

    func testUndoReversesPinAndUnpin() {
        let store = makeStore()
        XCTAssertTrue(store.isMetricEnabled("cursor.usage"))
        XCTAssertFalse(store.isPinned("cursor.usage"))

        store.setPinned(true, for: "cursor.usage")
        XCTAssertTrue(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"), "undo reverses a pin")

        XCTAssertTrue(store.isPinned("claude.session"))
        store.setPinned(false, for: "claude.session")
        XCTAssertFalse(store.isPinned("claude.session"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isPinned("claude.session"), "undo reverses an unpin")
    }

    func testUndoWalksBackMultipleMixedSteps() {
        let store = makeStore()
        store.setMetricEnabled("cursor.today", true)
        store.setPinned(true, for: "cursor.usage")
        store.setMetricEnabled("claude.session", false)

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("cursor.usage"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.today"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore()
        store.setMetricEnabled("claude.weekly", true)
        var pinned = false
        for _ in 0..<(LayoutStore.maxUndoDepth + 10) {
            pinned.toggle()
            store.setPinned(pinned, for: "claude.weekly")
        }
        var steps = 0
        while store.undo() { steps += 1 }
        XCTAssertEqual(steps, LayoutStore.maxUndoDepth)
    }

    func testNoOpActionDoesNotRecordUndoStep() {
        let store = makeStore()
        store.setMetricEnabled("cursor.today", true)
        store.setMetricEnabled("cursor.today", true)
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo)
    }

    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults)

        for descriptor in store.visibleDescriptors {
            store.setMetricEnabled(descriptor.id, false)
        }

        let reloaded = makeStore(defaults)
        XCTAssertTrue(reloaded.visibleDescriptors.isEmpty)
    }

    func testTogglingMetricDoesNotChangeCustomizeOrder() {
        let store = makeStore()
        let before = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))

        store.setMetricEnabled("cursor.today", true)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)

        store.setMetricEnabled("cursor.today", false)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)
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

    func testFreshDefaultLayoutSeedsMetricsForAccountCards() {
        let account = Account(kind: .claude, label: "Work")
        let providers = ProviderCatalog.make(accounts: [account], vault: InMemoryCredentialVault())
        let store = makeStore(registry: .from(providers))

        XCTAssertTrue(store.isMetricEnabled("\(account.cardID).session"))
        XCTAssertTrue(store.visibleDescriptors.contains { $0.id == "\(account.cardID).session" })
    }

    func testFreshDefaultLayoutEnablesTheResetsRowForEachAccount() {
        let accounts = [Account(kind: .claude, label: "Work"), Account(kind: .codex, label: "Work")]
        let providers = ProviderCatalog.make(accounts: accounts, vault: InMemoryCredentialVault())
        let cardIDs = accounts.map(\.cardID)
        let store = makeStore(registry: .from(providers))

        for cardID in cardIDs {
            let resetsID = "\(cardID).rateLimitResets"
            XCTAssertTrue(store.isMetricEnabled(resetsID), resetsID)
            XCTAssertTrue(store.visibleDescriptors.contains { $0.id == resetsID }, resetsID)
        }
    }

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults, hidden: ["claude.weekly", "claude.extra", "claude.today"])
        let original = store.orderedSupportedMetrics(for: "claude").map(\.id)
        guard let first = original.first else { return XCTFail("missing Claude metrics") }
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.reorderMetric(dragged: "claude.extra", target: first, in: "claude")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")

        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
    }

    func testFreshStoreSeedsDefaultPins() {
        let store = makeStore()
        let expected = Set(MockData.descriptors.filter(\.isPinnedByDefault).map(\.id))

        XCTAssertFalse(expected.isEmpty, "fixture registry should know some default-pinned metrics")
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testUnpinningEverythingPersistsAndIsNotReseeded() {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults)
        XCTAssertFalse(store.pinnedMetricIDs.isEmpty)

        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let reloaded = makeStore(defaults)
        XCTAssertTrue(reloaded.pinnedMetricIDs.isEmpty, "an explicitly emptied pin set must not be reseeded")
    }

    func testHidingAStarredMetricUnstarsItAndUndoRestoresBoth() {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults)
        XCTAssertTrue(store.isPinned("claude.session"))
        XCTAssertTrue(trayMetricIDs(store).contains("claude.session"))

        store.setMetricEnabled("claude.session", false)
        XCTAssertFalse(store.isPinned("claude.session"))
        XCTAssertFalse(trayMetricIDs(store).contains("claude.session"), "the tray drops a hidden metric")
        XCTAssertFalse(makeStore(defaults).isPinned("claude.session"),
                       "the unstar is saved")

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("claude.session"), "one undo restores the metric and its star")
        XCTAssertTrue(trayMetricIDs(store).contains("claude.session"))
        XCTAssertTrue(makeStore(defaults).isPinned("claude.session"))
    }

    func testShowingAHiddenMetricAgainDoesNotStarIt() {
        let store = makeStore()
        store.setMetricEnabled("claude.session", false)
        store.setMetricEnabled("claude.weekly", false)

        store.setMetricEnabled("claude.session", true)
        store.showMetrics(["claude.weekly"])
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isPinned("claude.session"))
        XCTAssertFalse(store.isPinned("claude.weekly"))
    }

    func testStarringAHiddenMetricShowsIt() {
        let store = makeStore()
        store.setMetricEnabled("cursor.usage", false)

        store.setPinned(true, for: "cursor.usage")
        XCTAssertTrue(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"))
        XCTAssertFalse(store.isMetricEnabled("cursor.usage"), "one undo takes back the star and the show")
    }

    func testSavedStarOnAHiddenMetricIsDroppedAtLoad() {
        let defaults = isolatedDefaults()
        LayoutPersistence(defaults: defaults).save(LayoutState(
            hiddenMetricIDs: ["claude.session"],
            pinnedMetricIDs: ["claude.session", "claude.weekly"],
            seededProviderIDs: Set(MockData.providers.map(\.id))
        ))

        let store = makeStore(defaults)
        XCTAssertFalse(store.isMetricEnabled("claude.session"))
        XCTAssertEqual(store.pinnedMetricIDs, ["claude.weekly"])
        XCTAssertFalse(trayMetricIDs(store).contains("claude.session"))

        store.setMetricEnabled("claude.session", true)
        XCTAssertFalse(makeStore(defaults).isPinned("claude.session"), "showing the metric again does not bring the star back")
    }

    func testDisplayGroupsListEveryEnabledMetricInMetricOrder() {
        let store = makeStore(hidden: ["claude.extra", "claude.today"])

        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.metrics.map(\.id), ["claude.weekly", "claude.session"])
        XCTAssertEqual(store.customizeDetail(for: "claude")?.metrics.prefix(2).map(\.id), ["claude.weekly", "claude.session"])
    }

    func testAccountListFollowsReorder() {
        let store = makeStore()
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertEqual(store.orderedProviders().map(\.id), ["cursor", "claude", "codex"])
        XCTAssertEqual(store.displayGroups.map(\.provider.id), ["cursor", "claude", "codex"])
    }

    func testCustomizeDetailReturnsMetrics() {
        let store = makeStore()
        let detail = store.customizeDetail(for: "codex")
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.metrics.map(\.id), MockData.descriptors(for: "codex").map(\.id))
    }

    func testCustomizeDetailIsNilForUnknownProvider() {
        let store = makeStore()
        XCTAssertNil(store.customizeDetail(for: "nope"))
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

    private func makeStore(
        _ defaults: UserDefaults? = nil,
        registry: WidgetRegistry = .mock,
        hidden: [String] = ["claude.today", "codex.today", "cursor.today"]
    ) -> LayoutStore {
        let defaults = defaults ?? isolatedDefaults()
        let persistence = LayoutPersistence(defaults: defaults)
        if persistence.load() == nil { persistence.save(LayoutState(hiddenMetricIDs: Set(hidden))) }
        return LayoutStore(registry: registry, defaults: defaults)
    }

    private func trayMetricIDs(_ store: LayoutStore) -> [String] {
        MenuBarContentBuilder.build(groups: store.pinnedGroups, data: { $0.sample }).groups.flatMap { $0.metrics.map(\.id) }
    }
}
