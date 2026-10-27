import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testRemoveClearsDragStateAndAllowsRepeatedRemoval() {
        let store = makeStore()
        let first = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs[0])
        let second = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs[1])
        store.placed = [first, second]
        store.draggingID = first.id

        store.remove(first.id)

        XCTAssertNil(store.draggingID)
        XCTAssertEqual(store.placed, [second])

        store.remove(second.id)

        XCTAssertTrue(store.placed.isEmpty)
    }

    // MARK: - Undo

    func testUndoRestoresRemovedMetricToSamePosition() {
        let store = makeStore()
        // Enable Claude's full set so the order is well-defined and the removed metric has neighbours.
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)
        let enabledBefore = store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID)

        // Remove a middle metric, then undo it.
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())

        // Re-enabled and back in its exact slot, with the enabled placed order unchanged.
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)
        XCTAssertEqual(
            store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID),
            enabledBefore
        )
    }

    func testUndoReversesEnable() {
        let store = makeStore()
        // cursor.today is not in DefaultLayout.metricIDs, so it starts disabled in the mock.
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
        // cursor.usage is enabled by default but not pinned (cursor's default pins aren't in the mock).
        XCTAssertTrue(store.isMetricEnabled("cursor.usage"))
        XCTAssertFalse(store.isPinned("cursor.usage"))

        // Pin, then undo → back to unpinned.
        store.setPinned(true, for: "cursor.usage")
        XCTAssertTrue(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"), "undo reverses a pin")

        // Unpin a default-pinned metric, then undo → back to pinned.
        XCTAssertTrue(store.isPinned("claude.session"))
        store.setPinned(false, for: "claude.session")
        XCTAssertFalse(store.isPinned("claude.session"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isPinned("claude.session"), "undo reverses an unpin")
    }

    func testUndoWalksBackMultipleMixedSteps() {
        let store = makeStore()
        // Distinct, real changes: enable an off metric, pin an unpinned one, remove an on metric.
        store.setMetricEnabled("cursor.today", true)  // step 1: enable
        store.setPinned(true, for: "cursor.usage")      // step 2: pin
        store.setMetricEnabled("claude.session", false) // step 3: remove

        // Walk back in reverse order, one step per ⌘Z.
        XCTAssertTrue(store.undo())                      // undo remove
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("cursor.usage"))

        XCTAssertTrue(store.undo())                      // undo pin
        XCTAssertFalse(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.today"))

        XCTAssertTrue(store.undo())                      // undo enable
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore()
        // Drive more distinct, recordable changes than the cap by toggling a pin on and off repeatedly.
        store.setMetricEnabled("claude.weekly", true)
        var pinned = false
        for _ in 0..<(LayoutUndoHistory.maxDepth + 10) {
            pinned.toggle()
            store.setPinned(pinned, for: "claude.weekly")
        }
        // Undo can only walk back the cap's worth of steps, then stops.
        var steps = 0
        while store.undo() { steps += 1 }
        XCTAssertEqual(steps, LayoutUndoHistory.maxDepth)
    }

    func testNoOpActionDoesNotRecordUndoStep() {
        let store = makeStore()
        store.setMetricEnabled("cursor.today", true)  // one real step
        // Re-enabling an already-on metric, or a self-target reorder, changes nothing → no step.
        store.setMetricEnabled("cursor.today", true)
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        // Exactly one undoable step (the original enable).
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo)
    }

    func testUndoWithEmptyHistoryIsNoOp() {
        let store = makeStore()
        let before = store.placed.map(\.descriptorID)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        for widget in store.placed {
            store.remove(widget.id)
        }

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.placed.isEmpty)
    }

    func testUnreadableSeedMarkerKeepsExistingUserBaseline() {
        let defaults = isolatedDefaults()
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(Data("not valid seeded-default data".utf8), forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
    }

    func testExistingLayoutAutoSeedsOnlyDefaultsAddedAfterBaseline() {
        let defaults = isolatedDefaults()
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session", "claude.today"])
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"), "baseline defaults the user already removed stay off")
    }

    func testDisablingAutoSeededDefaultDoesNotReAddOnReload() {
        let defaults = isolatedDefaults()
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        guard let seeded = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("new default was not seeded")
        }

        store.remove(seeded.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testFreshLayoutTreatsCurrentDefaultsAsAlreadySeeded() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("fresh store did not include all current defaults")
        }

        store.remove(today.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testAutoSeedingIgnoresUnknownDefaultIDs() {
        let defaults = isolatedDefaults()
        saveStored([PlacedWidget](), forKey: "layout", in: defaults)

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["missing.metric", "claude.session"],
            migrationBaselineMetricIDs: []
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
    }

    func testAddAndRemoveCancelDragState() {
        let store = makeStore()
        let first = store.placed[0]

        store.draggingID = first.id
        store.remove(first.id)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.add(first.descriptorID)
        XCTAssertNil(store.draggingID)
    }

    func testAddAndRemoveTogglePlacement() {
        let store = makeStore()
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))

        store.add("cursor.today")
        XCTAssertTrue(store.isMetricEnabled("cursor.today"))

        guard let widget = store.placed.first(where: { $0.descriptorID == "cursor.today" }) else {
            return XCTFail("missing widget")
        }
        store.remove(widget.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.today"))
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
        let store = LayoutStore(
            registry: WidgetRegistry.from(providers), defaults: isolatedDefaults(), storageKey: "layout"
        )

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
        let defaults = DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: [account.cardID])
        let store = LayoutStore(
            registry: WidgetRegistry.from(providers),
            defaults: isolatedDefaults(),
            storageKey: "layout",
            defaultMetricIDs: defaults
        )

        XCTAssertTrue(store.isMetricEnabled("\(account.cardID).session"))
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "\(account.cardID).session" })
    }

    func testFreshDefaultLayoutEnablesTheResetsRowForEachAccount() {
        let accounts = [Account(kind: .claude, label: "Work"), Account(kind: .codex, label: "Work")]
        let providers = ProviderCatalog.make(accounts: accounts, vault: InMemoryCredentialVault())
        let cardIDs = accounts.map(\.cardID)
        let store = LayoutStore(
            registry: WidgetRegistry.from(providers),
            defaults: isolatedDefaults(),
            storageKey: "layout",
            defaultMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: cardIDs)
        )

        for cardID in cardIDs {
            let resetsID = "\(cardID).rateLimitResets"
            XCTAssertTrue(store.isMetricEnabled(resetsID), resetsID)
            XCTAssertTrue(store.placed.contains { $0.descriptorID == resetsID }, resetsID)
        }
    }

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"]
        )
        let original = store.orderedSupportedMetrics(for: "claude").map(\.id)
        guard let first = original.first else { return XCTFail("missing Claude metrics") }
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.reorderMetric(dragged: "claude.extra", target: first, in: "claude")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")

        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
    }

    func testFreshStoreSeedsDefaultPins() {
        let store = makeStore()
        let expected = Set(DefaultLayout.pinnedMetricIDs.filter { MockData.descriptor($0) != nil })

        XCTAssertFalse(expected.isEmpty, "fixture registry should know some default-pinned metrics")
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testUnpinningEverythingPersistsAndIsNotReseeded() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.pinnedMetricIDs.isEmpty)

        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.pinnedMetricIDs.isEmpty, "an explicitly emptied pin set must not be reseeded")
    }

    // MARK: - Hiding unstars

    func testHidingAStarredMetricUnstarsItAndUndoRestoresBoth() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.isPinned("claude.session"))
        XCTAssertTrue(trayMetricIDs(store).contains("claude.session"))

        store.setMetricEnabled("claude.session", false)
        XCTAssertFalse(store.isPinned("claude.session"))
        XCTAssertFalse(trayMetricIDs(store).contains("claude.session"), "the tray drops a hidden metric")
        XCTAssertFalse(LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout").isPinned("claude.session"),
                       "the unstar is saved")

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("claude.session"), "one undo restores the metric and its star")
        XCTAssertTrue(trayMetricIDs(store).contains("claude.session"))
        XCTAssertTrue(LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout").isPinned("claude.session"))
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

    /// A layout saved before hiding unstarred can hold a star on a hidden metric. Loading it drops that
    /// star, keeps the others, and saves the fix.
    func testSavedStarOnAHiddenMetricIsDroppedAtLoad() {
        let defaults = isolatedDefaults()
        let shown = DefaultLayout.metricIDs.filter { MockData.descriptor($0) != nil && $0 != "claude.session" }
        saveStored(shown.map { PlacedWidget(descriptorID: $0) }, forKey: "layout", in: defaults)
        defaults.set(["claude.session", "claude.weekly"], forKey: "layout.menuBarPins")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.isMetricEnabled("claude.session"))
        XCTAssertEqual(store.pinnedMetricIDs, ["claude.weekly"])
        XCTAssertFalse(trayMetricIDs(store).contains("claude.session"))
        XCTAssertEqual(defaults.stringArray(forKey: "layout.menuBarPins"), ["claude.weekly"])
    }

    /// A metric is either enabled or not: every enabled metric is in the provider's one list, in the
    /// saved metric order, and the Accounts detail lists the same order.
    func testDisplayGroupsListEveryEnabledMetricInMetricOrder() {
        let store = LayoutStore(
            registry: .mock,
            defaults: isolatedDefaults(),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.widgets.map(\.descriptorID), ["claude.weekly", "claude.session"])
        XCTAssertEqual(store.customizeDetail(for: "claude")?.metrics.prefix(2).map(\.id), ["claude.weekly", "claude.session"])
    }

    // MARK: - Accounts master/detail (L1 list + L2 detail)

    func testAccountListIncludesAllProviders() {
        let store = LayoutStore(
            registry: .mock,
            defaults: isolatedDefaults(),
            storageKey: "layout"
        )
        XCTAssertEqual(store.orderedProviders().map(\.id), MockData.providers.map(\.id))
    }

    func testAccountListFollowsReorder() {
        let store = makeStore()
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertEqual(store.orderedProviders().map(\.id), ["cursor", "claude", "codex"])
        XCTAssertEqual(store.displayGroups.map(\.provider.id), ["cursor", "claude", "codex"])
    }

    func testCustomizeDetailReturnsMetrics() {
        let store = LayoutStore(
            registry: .mock,
            defaults: isolatedDefaults(),
            storageKey: "layout"
        )
        let detail = store.customizeDetail(for: "codex")
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.metrics.map(\.id), MockData.descriptors(for: "codex").map(\.id))
    }

    func testCustomizeDetailIsNilForUnknownProvider() {
        let store = makeStore()
        XCTAssertNil(store.customizeDetail(for: "nope"))
    }

    func testCustomizeProviderIDClearsWhenLeavingAccounts() {
        let store = makeStore()
        store.screen = .accounts
        store.customizeProviderID = "claude"
        XCTAssertEqual(store.customizeProviderID, "claude")

        store.screen = .dashboard
        XCTAssertNil(store.customizeProviderID, "leaving Accounts resets the L2 selection back to the list")

        // A direct jump to Settings also clears it — never strand a detail selection on another screen.
        store.screen = .accounts
        store.customizeProviderID = "codex"
        store.screen = .settings
        XCTAssertNil(store.customizeProviderID)
    }

    // MARK: - Share confirmation

    /// `clearShareConfirmation` hides the pill immediately and cancels the auto-clear task, so a
    /// confirmation mid-countdown can't reappear stale after the popover closes and reopens.
    func testClearShareConfirmationHidesPillAndCancelsTimer() {
        let store = makeStore()
        XCTAssertFalse(store.shareConfirmation)

        store.presentShareConfirmation()
        XCTAssertTrue(store.shareConfirmation, "present sets the confirmation the pill reads")

        store.clearShareConfirmation()
        XCTAssertFalse(store.shareConfirmation, "clear hides the pill immediately")
    }

    private func makeStore() -> LayoutStore {
        LayoutStore(registry: .mock, defaults: isolatedDefaults(), storageKey: "layout")
    }

    /// The metrics the menu bar strip shows, as `StatusItemImageUpdater` builds it.
    private func trayMetricIDs(_ store: LayoutStore) -> [String] {
        MenuBarContentBuilder.build(groups: store.pinnedGroups, data: { $0.sample }).groups.flatMap { $0.metrics.map(\.id) }
    }


    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
