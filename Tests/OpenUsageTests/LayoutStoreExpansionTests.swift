import XCTest
@testable import OpenUsage

@MainActor
extension LayoutStoreTests {
    // MARK: - Expanded ("Shown on expand") membership

    func testDividerDragMovesMetricBelowDividerAndPersists() {
        let defaults = makeDefaults("ExpandMove")
        // Hermetic: start with nothing below the caret (independent of DefaultLayout's seeding).
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout", defaultExpandedMetricIDs: [])
        guard let first = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(store.expandedMetricIDs.contains(first))

        XCTAssertTrue(moveMetric(first, expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains(first))

        let group = store.customizeGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.expandedMetrics.map(\.id).first, first)
        XCTAssertFalse(group?.alwaysShownMetrics.map(\.id).contains(first) ?? true)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.expandedMetricIDs.contains(first))
    }

    func testDividerDragIsNoOpWhenAlreadyInSection() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ExpandNoOp"), storageKey: "layout", defaultExpandedMetricIDs: [])
        guard let id = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(moveMetric(id, expanded: false, in: store), "already always-shown")
        XCTAssertTrue(moveMetric(id, expanded: true, in: store))
        XCTAssertFalse(moveMetric(id, expanded: true, in: store), "already expanded")
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
        XCTAssertTrue(moveMetric(target, expanded: true, in: store))
        XCTAssertFalse(store.expandedMetricIDs.contains(dragged))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))

        XCTAssertTrue(store.expandedMetricIDs.contains(dragged), "dropping onto an expanded row moves the dragged row across")
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
        XCTAssertTrue(moveMetric(dragged, expanded: true, in: store))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))
        XCTAssertFalse(store.expandedMetricIDs.contains(dragged), "dropping onto an always-shown row brings the dragged row back")
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
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.usage"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
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
        XCTAssertTrue(moveMetric("cursor.requests", expanded: true, in: store))

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.requests",
            divider,
            "cursor.credits",
            "cursor.today"
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))
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
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.credits", "cursor.today", "cursor.requests"
        ])
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.today"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
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

        XCTAssertTrue(moveMetric("claude.extra", expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.extra"))
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("claude.extra"))
    }

    func testFreshLayoutSeedsDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("FreshExpanded"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.weekly"))
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
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.weekly"), "an existing layout keeps every metric always-shown")
    }

    func testResetRestoresDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("ResetExpand"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(moveMetric("claude.weekly", expanded: false, in: store))
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.weekly"))

        store.resetToDefault()
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.weekly"))
    }

    func testInvalidPersistedExpandedIDsAreDropped() {
        let defaults = makeDefaults("InvalidExpand")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.session", "missing.metric"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.session"))
        XCTAssertFalse(store.expandedMetricIDs.contains("missing.metric"))
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

        XCTAssertTrue(moveMetric("claude.weekly", expanded: true, in: store))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.alwaysShownWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.session"])
        XCTAssertEqual(group?.expandedWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.weekly"])
        XCTAssertEqual(group?.hasExpandedMetrics, true)
    }

    func testProviderWithOnlyExpandedMetricsStillShowsRows() {
        // Only session + weekly enabled, both primary to start, so expanding both makes the whole
        // provider expanded — independent of DefaultLayout's seeding.
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("AllExpanded"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(moveMetric("claude.session", expanded: true, in: store))
        XCTAssertTrue(moveMetric("claude.weekly", expanded: true, in: store))

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

}
