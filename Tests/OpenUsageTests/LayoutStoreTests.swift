import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testRemoveClearsDragStateAndAllowsRepeatedRemoval() {
        let store = makeStore("RepeatedRemoval")
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

    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = makeDefaults("EmptyLayout")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        for widget in store.placed {
            store.remove(widget.id)
        }

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.placed.isEmpty)
    }

    func testExistingLayoutAutoSeedsOnlyDefaultsAddedAfterBaseline() {
        let defaults = makeDefaults("SeedNewDefault")
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
        let defaults = makeDefaults("SeedOnce")
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
        let defaults = makeDefaults("FreshSeeded")
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
        let defaults = makeDefaults("UnknownSeed")
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

    func testExistingLayoutEnablesDefaultExpandedOptionalBelowCaret() {
        let defaults = makeDefaults("LegacyEnableExpanded")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )

        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.isMetricExpanded("cursor.requests"))

        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricEnabled("cursor.requests"))
        XCTAssertTrue(store.isMetricExpanded("cursor.requests"))
    }

    func testExplicitDividerMoveOverridesDefaultExpandedOnEnable() {
        let defaults = makeDefaults("LegacyEnableExpandedOverride")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.requests",
            divider,
            "cursor.credits",
            "cursor.today"
        ], dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.isMetricExpanded("cursor.requests"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertFalse(reloaded.isMetricExpanded("cursor.requests"))
    }

    func testPrimaryDividerReorderDoesNotConsumeHiddenDefaultExpandedOnEnable() {
        let defaults = makeDefaults("LegacyPrimaryReorderKeepsFallback")
        saveStored([
            PlacedWidget(descriptorID: "cursor.usage"),
            PlacedWidget(descriptorID: "cursor.today")
        ], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            migrationBaselineMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.today",
            "cursor.usage",
            divider
        ], dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricExpanded("cursor.requests"))
    }

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
            "claude.session", "claude.weekly", "claude.sonnet", "claude.extra",
            "claude.trend", "claude.today", "claude.yesterday", "claude.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "codex").map(\.id), [
            "codex.session", "codex.weekly", "codex.credits", "codex.rateLimitResets",
            "codex.trend", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "devin").map(\.id), [
            "devin.daily", "devin.weekly", "devin.extra"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "grok").map(\.id), [
            "grok.creditsUsed", "grok.payAsYouGo",
            "grok.trend", "grok.today", "grok.yesterday", "grok.last30"
        ])
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
            "codex.session", "codex.weekly", "codex.trend",
            "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",
            "devin.daily", "devin.weekly", "devin.extra",
            "grok.creditsUsed", "grok.trend",
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",
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

        XCTAssertEqual(primaryByProvider["claude"], ["claude.session", "claude.weekly", "claude.trend"])
        XCTAssertEqual(expandedByProvider["claude"], [
            "claude.sonnet", "claude.extra", "claude.today", "claude.yesterday", "claude.last30"
        ])
        XCTAssertEqual(primaryByProvider["codex"], ["codex.session", "codex.weekly", "codex.trend"])
        XCTAssertEqual(expandedByProvider["codex"], [
            "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(primaryByProvider["devin"], ["devin.daily", "devin.weekly"])
        XCTAssertEqual(expandedByProvider["devin"], ["devin.extra"])
        XCTAssertEqual(primaryByProvider["grok"], ["grok.creditsUsed", "grok.trend"])
        XCTAssertEqual(expandedByProvider["grok"], [
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"
        ])
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

    // MARK: - Expanded ("Shown on expand") membership

    func testSetMetricExpandedMovesMetricBelowDividerAndPersists() {
        let defaults = makeDefaults("ExpandMove")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        guard let first = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(store.isMetricExpanded(first))

        XCTAssertTrue(store.setMetricExpanded(first, true))
        XCTAssertTrue(store.isMetricExpanded(first))

        let group = store.customizeGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.expandedMetrics.map(\.id).first, first)
        XCTAssertFalse(group?.alwaysShownMetrics.map(\.id).contains(first) ?? true)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.isMetricExpanded(first))
    }

    func testSetMetricExpandedIsNoOpWhenAlreadyInSection() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ExpandNoOp"), storageKey: "layout")
        guard let id = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(store.setMetricExpanded(id, false), "already always-shown")
        XCTAssertTrue(store.setMetricExpanded(id, true))
        XCTAssertFalse(store.setMetricExpanded(id, true), "already expanded")
    }

    func testDraggingMetricOntoExpandedRowTucksItAway() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DragAcross"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let ids = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        guard ids.count >= 2, let dragged = ids.first, let target = ids.last else {
            return XCTFail("need at least two Cursor metrics")
        }
        XCTAssertTrue(store.setMetricExpanded(target, true))
        XCTAssertFalse(store.isMetricExpanded(dragged))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))

        XCTAssertTrue(store.isMetricExpanded(dragged), "dropping onto an expanded row moves the dragged row across")
        let expanded = store.customizeGroups.first { $0.provider.id == "cursor" }?.expandedMetrics.map(\.id) ?? []
        XCTAssertTrue(expanded.contains(dragged) && expanded.contains(target))
    }

    func testDraggingExpandedMetricOntoAlwaysShownRowBringsItBack() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DragBack"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let ids = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        guard ids.count >= 2, let target = ids.first, let dragged = ids.last else {
            return XCTFail("need at least two Cursor metrics")
        }
        XCTAssertTrue(store.setMetricExpanded(dragged, true))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))
        XCTAssertFalse(store.isMetricExpanded(dragged), "dropping onto an always-shown row brings the dragged row back")
    }

    func testApplyingDividerOrderMovesMetricBelowFold() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DividerDown"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            divider,
            "cursor.requests",
            "cursor.credits",
            "cursor.today"
        ], dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.isMetricExpanded("cursor.usage"))
        XCTAssertTrue(store.isMetricExpanded("cursor.requests"))
    }

    func testApplyingDividerOrderMovesMetricAboveFold() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DividerUp"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let divider = "cursor::expanded-divider"
        XCTAssertTrue(store.setMetricExpanded("cursor.requests", true))

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.requests",
            divider,
            "cursor.credits",
            "cursor.today"
        ], dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.isMetricExpanded("cursor.requests"))
    }

    func testApplyingVisibleDividerOrderKeepsDisabledMetricsInPlace() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("VisibleDividerKeepsDisabled"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: ["cursor.requests", "cursor.today"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.today",
            divider
        ], dividerID: divider, in: "cursor"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.credits", "cursor.today", "cursor.requests"
        ])
        XCTAssertFalse(store.isMetricExpanded("cursor.today"))
        XCTAssertTrue(store.isMetricExpanded("cursor.requests"))
    }

    func testDisabledMetricKeepsExpandedMembership() {
        let defaults = makeDefaults("DisabledExpanded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        XCTAssertTrue(store.setMetricExpanded("claude.extra", true))
        XCTAssertTrue(store.isMetricExpanded("claude.extra"))
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(reloaded.isMetricExpanded("claude.extra"))
    }

    func testFreshLayoutSeedsDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("FreshExpanded"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(store.isMetricExpanded("claude.weekly"))
    }

    func testExistingLayoutDoesNotSeedExpanded() {
        let defaults = makeDefaults("ExistingNoExpand")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertFalse(store.isMetricExpanded("claude.weekly"), "an existing layout keeps every metric always-shown")
    }

    func testResetRestoresDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("ResetExpand"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(store.setMetricExpanded("claude.weekly", false))
        XCTAssertFalse(store.isMetricExpanded("claude.weekly"))

        store.resetToDefault()
        XCTAssertTrue(store.isMetricExpanded("claude.weekly"))
    }

    func testInvalidPersistedExpandedIDsAreDropped() {
        let defaults = makeDefaults("InvalidExpand")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.session", "missing.metric"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.isMetricExpanded("claude.session"))
        XCTAssertFalse(store.isMetricExpanded("missing.metric"))
    }

    func testDisplayGroupsPartitionEnabledMetrics() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DisplayPartition"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))

        XCTAssertTrue(store.setMetricExpanded("claude.weekly", true))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.alwaysShownWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.session"])
        XCTAssertEqual(group?.expandedWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.weekly"])
        XCTAssertEqual(group?.hasExpandedMetrics, true)
    }

    func testProviderWithOnlyExpandedMetricsStillShowsRows() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("AllExpanded"), storageKey: "layout")
        XCTAssertTrue(store.setMetricExpanded("claude.session", true))
        XCTAssertTrue(store.setMetricExpanded("claude.weekly", true))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertNotNil(group)
        XCTAssertFalse(group?.alwaysShownWidgets.isEmpty ?? true, "all-expanded metrics are promoted so the card is never empty")
        XCTAssertTrue(group?.expandedWidgets.isEmpty ?? false)
    }

    func testProviderExpandedStatePersistsAcrossReload() {
        let defaults = makeDefaults("ProviderExpanded")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.isProviderExpanded("codex"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.isProviderExpanded("codex"))
    }

    func testProviderExpandedStateCanCollapseAndPersists() {
        let defaults = makeDefaults("ProviderCollapsed")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.setProviderExpanded(false, for: "codex"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.isProviderExpanded("codex"))
    }

    func testInvalidPersistedExpandedProviderIDsAreDropped() {
        let defaults = makeDefaults("InvalidProviderExpanded")
        defaults.set(["codex", "missing"], forKey: "layout.expandedProviders")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.isProviderExpanded("codex"))
        XCTAssertFalse(store.isProviderExpanded("missing"))
    }

    func testResetClearsProviderExpandedState() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ResetProviderExpanded"), storageKey: "layout")
        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))

        store.resetToDefault()

        XCTAssertFalse(store.isProviderExpanded("codex"))
    }

    func testResetProviderRestoresOneProviderAndLeavesOthersAndOrderUntouched() {
        let defaults = makeDefaults("ResetOneProvider")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "codex.session"],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: ["claude.session", "codex.session"],
            defaultExpandedMetricIDs: []
        )

        // Reorder providers first, so we can prove a per-provider reset leaves provider order alone.
        store.reorderProvider(dragged: "cursor", target: "claude")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        // Diverge Claude from its defaults in every dimension a reset should restore.
        store.setMetricEnabled("claude.weekly", true)
        store.setPinned(true, for: "claude.weekly")
        store.setProviderExpanded(true, for: "claude")
        store.reorderMetric(dragged: "claude.extra", target: "claude.session", in: "claude")

        // Diverge Codex too — a Claude reset must not touch it.
        store.setMetricEnabled("codex.weekly", true)
        store.setPinned(true, for: "codex.weekly")

        store.resetProvider("claude")

        // Claude restored: enabled set, metric order, pins, and expanded state back to default.
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isPinned("claude.session"))
        XCTAssertFalse(store.isPinned("claude.weekly"))
        XCTAssertFalse(store.isProviderExpanded("claude"))
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "claude").map(\.id),
            MockData.descriptors(for: "claude").map(\.id)
        )

        // Codex untouched by a Claude-only reset.
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(store.isPinned("codex.weekly"))

        // Provider order untouched — contents-only reset.
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore)
    }

    func testResetProviderIsNoOpForUnknownProvider() {
        let store = makeStore("ResetUnknownProvider")
        let before = store.placed.map(\.descriptorID)
        store.resetProvider("nope")
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .mock, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.LayoutStore.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
