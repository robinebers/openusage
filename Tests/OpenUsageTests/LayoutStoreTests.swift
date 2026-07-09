import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testRemoveClearsDragStateAndAllowsRepeatedRemoval() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("RepeatedRemoval"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"]
        )
        guard store.placed.count == 2 else { return XCTFail("expected two default widgets") }
        let first = store.placed[0]
        let second = store.placed[1]
        store.draggingID = first.id

        store.remove(first.id)

        XCTAssertNil(store.draggingID)
        XCTAssertEqual(store.placed, [second])

        store.remove(second.id)

        XCTAssertTrue(store.placed.isEmpty)
    }

    // MARK: - Placement, ordering, and defaults

    func testAddAndResetCancelDragState() {
        let store = makeStore("CancelDrag")
        let first = store.placed[0]

        store.draggingID = first.id
        store.remove(first.id)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.add(first.descriptorID)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.resetToDefault()
        XCTAssertNil(store.draggingID)
    }

    func testAddAndRemoveTogglePlacement() {
        let store = makeStore("Toggle")
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.add("cursor.credits")
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        guard let widget = store.placed.first(where: { $0.descriptorID == "cursor.credits" }) else {
            return XCTFail("missing widget")
        }
        store.remove(widget.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
    }

    func testPlanWidgetsAreNotRegisteredAsAddableMetrics() {
        let store = makeStore("Plans")
        XCTAssertFalse(store.availableToAdd.contains { PlanWidget.isPlan($0) })
    }

    func testTogglingMetricDoesNotChangeCustomizeOrder() {
        let store = makeStore("ToggleKeepsOrder")
        let before = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)

        store.setMetricEnabled("cursor.credits", false)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)
    }

    func testFreshCustomizeOrderFollowsProviderDeclarations() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("FreshCustomizeOrder"), storageKey: "layout")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), [
            "claude.session", "claude.weekly", "claude.sonnet", "claude.fable", "claude.extra",
            "claude.trend", "claude.today", "claude.yesterday", "claude.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "codex").map(\.id), [
            "codex.session", "codex.weekly", "codex.spark", "codex.sparkWeekly",
            "codex.credits", "codex.rateLimitResets",
            "codex.trend", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "devin").map(\.id), [
            "devin.daily", "devin.weekly", "devin.extra"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "grok").map(\.id), [
            "grok.weekly", "grok.payAsYouGo",
            "grok.trend", "grok.today", "grok.yesterday", "grok.last30"
        ])
        // Cursor's spend tiles + usage trend are enabled, so they trail the live meters in declaration order.
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.onDemand", "cursor.requests",
            "cursor.credits", "cursor.trend", "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testFreshDefaultLayoutMatchesRecommendedMetricSections() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("RecommendedDefaults"), storageKey: "layout")

        XCTAssertEqual(Set(store.placed.map(\.descriptorID)), Set([
            "claude.session", "claude.weekly", "claude.trend",
            "claude.extra", "claude.today", "claude.yesterday", "claude.last30",
            "codex.session", "codex.weekly", "codex.spark", "codex.sparkWeekly", "codex.trend",
            "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",
            "devin.daily", "devin.weekly", "devin.extra",
            "grok.weekly", "grok.trend",
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",
            // Cursor spend tiles + usage trend are enabled, joining its live meters in the default layout.
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
            "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
        ]))
        XCTAssertFalse(store.isMetricEnabled("claude.sonnet"))
        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        let primaryByProvider = Dictionary(uniqueKeysWithValues: store.customizeGroups.map {
            ($0.provider.id, $0.alwaysShownMetrics.map(\.id))
        })
        let expandedByProvider = Dictionary(uniqueKeysWithValues: store.customizeGroups.map {
            ($0.provider.id, $0.expandedMetrics.map(\.id))
        })

        // Claude's core meters (Session, Weekly, Extra, Usage Trend) stay primary; spend-history rows
        // go below the caret — the same "core above, history below" shape as the other providers.
        XCTAssertEqual(primaryByProvider["claude"], ["claude.session", "claude.weekly", "claude.extra", "claude.trend"])
        XCTAssertEqual(expandedByProvider["claude"], ["claude.sonnet", "claude.fable", "claude.today", "claude.yesterday", "claude.last30"])
        XCTAssertEqual(primaryByProvider["codex"], ["codex.session", "codex.weekly", "codex.trend"])
        // Spark (the optional model-specific limits) leads the expanded section, before credits.
        XCTAssertEqual(expandedByProvider["codex"], [
            "codex.spark", "codex.sparkWeekly",
            "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(primaryByProvider["devin"], ["devin.daily", "devin.weekly"])
        XCTAssertEqual(expandedByProvider["devin"], ["devin.extra"])
        XCTAssertEqual(primaryByProvider["grok"], ["grok.weekly", "grok.trend"])
        XCTAssertEqual(expandedByProvider["grok"], [
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"
        ])
        // Cursor spend tiles + usage trend are enabled: the trend joins the primary rows, and the
        // today/yesterday/last30 rows sit below the caret alongside the other secondary metrics.
        XCTAssertEqual(primaryByProvider["cursor"], ["cursor.usage", "cursor.auto", "cursor.api", "cursor.trend"])
        XCTAssertEqual(expandedByProvider["cursor"], [
            "cursor.onDemand", "cursor.requests", "cursor.credits",
            "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = makeDefaults("DisabledMetricOrder")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
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
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")

        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
    }

    func testFreshStoreSeedsDefaultPins() {
        let store = makeStore("SeedPins")
        let expected = Set(DefaultLayout.pinnedMetricIDs.filter { MockData.descriptor($0) != nil })

        XCTAssertFalse(expected.isEmpty, "fixture registry should know some default-pinned metrics")
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testUnpinningEverythingPersistsAndIsNotReseeded() {
        let defaults = makeDefaults("UnpinAll")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.pinnedMetricIDs.isEmpty)

        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.pinnedMetricIDs.isEmpty, "an explicitly emptied pin set must not be reseeded")
    }

    func testResetToDefaultRestoresDefaultPins() {
        let store = makeStore("ResetPins")
        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        store.resetToDefault()

        let expected = Set(DefaultLayout.pinnedMetricIDs.filter { MockData.descriptor($0) != nil })
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testResetToDefaultRestoresProviderOrderAndMarksDefaultsSeeded() {
        let defaults = makeDefaults("ResetSeeded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        store.resetToDefault()
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), MockData.providers.map(\.id))
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("reset did not restore current defaults")
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

    // MARK: - Share confirmation

    /// `clearShareConfirmation` hides the pill immediately and cancels the auto-clear task, so a
    /// confirmation mid-countdown can't reappear stale after the popover closes and reopens.
    func testClearShareConfirmationHidesPillAndCancelsTimer() {
        let store = makeStore("ShareConfirmationClear")
        XCTAssertFalse(store.shareConfirmation)

        store.presentShareConfirmation()
        XCTAssertTrue(store.shareConfirmation, "present sets the confirmation the pill reads")

        store.clearShareConfirmation()
        XCTAssertFalse(store.shareConfirmation, "clear hides the pill immediately")
    }

    /// Move a metric through the same divider-reorder route used by both dashboard and Customize
    /// drags. Tests use this only when they need to perform that real user action as setup.
    func moveMetric(_ descriptorID: String, expanded: Bool, in store: LayoutStore) -> Bool {
        guard store.expandedMetricIDs.contains(descriptorID) != expanded,
              let providerID = descriptorID.split(separator: ".", maxSplits: 1).first.map(String.init)
        else { return false }
        let dividerID = "\(providerID)::test-expanded-divider"
        let current = store.metricOrderWithDivider(for: providerID, dividerID: dividerID)
        guard let reordered = LayoutStore.reordered(current, dragged: descriptorID, target: dividerID) else {
            return false
        }
        return store.applyMetricDividerOrder(
            reordered,
            dragged: descriptorID,
            dividerID: dividerID,
            in: providerID
        )
    }

    func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .mock, defaults: makeDefaults(name), storageKey: "layout")
    }

    func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.LayoutStore.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
