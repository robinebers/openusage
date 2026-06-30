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

    // MARK: - Undo (#603)

    func testUndoRestoresRemovedMetricToSamePosition() {
        let store = makeStore("UndoRestoresPosition")
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
        let store = makeStore("UndoEnable")
        // cursor.credits is not in DefaultLayout.metricIDs, so it starts disabled in the mock.
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"), "undo turns an enabled metric back off")
    }

    func testUndoReversesMetricReorder() {
        let store = makeStore("UndoReorderMetric")
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
        let store = makeStore("UndoReorderProvider")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertNotEqual(store.customizeGroups.map(\.provider.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore,
                       "undo restores the exact prior provider order")
    }

    func testUndoReversesPinAndUnpin() {
        let store = makeStore("UndoPin")
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

    func testUndoReversesExpandedMove() {
        let store = makeStore("UndoExpandedMove")
        // claude.session stays above the fold by default (not in DefaultLayout.expandedMetricIDs).
        XCTAssertFalse(store.isMetricExpanded("claude.session"))

        store.setMetricExpanded("claude.session", true)
        XCTAssertTrue(store.isMetricExpanded("claude.session"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricExpanded("claude.session"), "undo moves the metric back above the caret")
    }

    func testUndoDoesNotRestoreProviderCardCaretState() {
        // Provider card expand/collapse is transient view state, not a layout edit, so undo must leave
        // the caret where the user last put it — not rewind it to whatever was open when the undone
        // step was recorded. Regression test for the snapshot wrongly capturing expandedProviderIDs.
        let store = makeStore("UndoLeavesProviderCaret")
        XCTAssertFalse(store.isProviderExpanded("codex"))

        // Open Codex's card, then make an undoable layout edit. The pre-edit snapshot must not capture
        // the open caret.
        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.isProviderExpanded("codex"))
        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.canUndo)

        // Collapse the card after the step was recorded, then undo the enable.
        XCTAssertTrue(store.setProviderExpanded(false, for: "codex"))
        XCTAssertFalse(store.isProviderExpanded("codex"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
        XCTAssertFalse(store.isProviderExpanded("codex"), "undo must not restore provider card caret state")
    }

    func testUndoWalksBackMultipleMixedSteps() {
        let store = makeStore("UndoMultiStep")
        // Distinct, real changes: enable an off metric, pin an unpinned one, remove an on metric.
        store.setMetricEnabled("cursor.credits", true)  // step 1: enable
        store.setPinned(true, for: "cursor.usage")      // step 2: pin
        store.setMetricEnabled("claude.session", false) // step 3: remove

        // Walk back in reverse order, one step per ⌘Z.
        XCTAssertTrue(store.undo())                      // undo remove
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("cursor.usage"))

        XCTAssertTrue(store.undo())                      // undo pin
        XCTAssertFalse(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        XCTAssertTrue(store.undo())                      // undo enable
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testUndoIsNotItselfRecorded() {
        // Applying an undo must not push a new step — otherwise ⌘Z would ping-pong forever.
        let store = makeStore("UndoNotRecorded")
        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo, "undo leaves nothing new to undo")
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore("UndoMaxDepth")
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
        let store = makeStore("UndoNoOp")
        store.setMetricEnabled("cursor.credits", true)  // one real step
        // Re-enabling an already-on metric, or a self-target reorder, changes nothing → no step.
        store.setMetricEnabled("cursor.credits", true)
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        // Exactly one undoable step (the original enable).
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo)
    }

    func testUndoWithEmptyHistoryIsNoOp() {
        let store = makeStore("UndoEmpty")
        let before = store.placed.map(\.descriptorID)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    func testResetToDefaultClearsUndoHistory() {
        let store = makeStore("UndoResetAllClears")
        store.setMetricEnabled("claude.weekly", true)
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertTrue(store.canUndo)

        store.resetToDefault()

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testResetProviderClearsUndoHistory() {
        let store = makeStore("UndoResetProviderClears")
        store.setMetricEnabled("cursor.credits", true)
        store.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(store.canUndo)

        store.resetProvider("claude")

        // Snapshots are whole-layout, so a reset (its own deliberate action) drops the entire stack.
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testDirectRemoveDoesNotRecordUndo() {
        // The low-level `remove(_:)` (used by drag teardown and tests) is not a user-facing seam, so it
        // doesn't feed the undo stack — only the wrapped mutations (setMetricEnabled, reorder, pin) do.
        let store = makeStore("UndoDirectRemove")
        store.placed = [PlacedWidget(descriptorID: "claude.weekly")]
        guard let widget = store.placed.first(where: { $0.descriptorID == "claude.weekly" }) else {
            return XCTFail("metric was not placed")
        }

        store.remove(widget.id)

        XCTAssertFalse(store.canUndo)
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

    func testNewlySeededDefaultExpandedMetricEntersBelowCaretForExistingLayout() {
        let defaults = makeDefaults("SeedNewExpanded")
        // An existing layout from before the new metric shipped, with a saved expanded set that can't
        // know about it yet.
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.today"]
        )

        // The new default is auto-enabled by migration AND tucked below the caret, not surfaced primary.
        XCTAssertTrue(store.isMetricEnabled("claude.today"))
        XCTAssertTrue(store.isMetricExpanded("claude.today"))
        // A metric the user already lived with stays always-shown.
        XCTAssertFalse(store.isMetricExpanded("claude.session"))

        // The new expanded membership persists across reloads.
        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.today"]
        )
        XCTAssertTrue(reloaded.isMetricExpanded("claude.today"))
    }

    func testMigrationPersistKeepsLegacyOptionalMetricExpandOnEnableAfterReload() {
        let defaults = makeDefaults("SeedExpandedKeepsFallback")
        // Legacy layout: predates the expanded feature (no saved expanded set).
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)

        let args: (UserDefaults) -> LayoutStore = { d in
            LayoutStore(
                registry: .mock,
                defaults: d,
                storageKey: "layout",
                defaultMetricIDs: ["cursor.usage", "claude.today"],
                migrationBaselineMetricIDs: ["cursor.usage"],
                // claude.today is a brand-new default (auto-enabled + tucked, persisting an expanded set);
                // cursor.requests is an optional default-expanded metric the user hasn't enabled yet.
                defaultExpandedMetricIDs: ["claude.today", "cursor.requests"]
            )
        }

        // First launch performs the migration and persists the expanded set.
        _ = args(defaults)

        // Second launch now sees a saved expanded set — the legacy optional metric must still enter below
        // the caret when first enabled (regression: persisting the migration zeroed the on-enable queue).
        let reloaded = args(defaults)
        XCTAssertFalse(reloaded.isMetricExpanded("cursor.requests"))
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.isMetricExpanded("cursor.requests"))
    }

    func testConsumedExpandOnEnableStaysConsumedAcrossRelaunch() {
        let defaults = makeDefaults("ExpandOnEnablePersists")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)

        let args: (UserDefaults) -> LayoutStore = { d in
            LayoutStore(
                registry: .mock,
                defaults: d,
                storageKey: "layout",
                defaultMetricIDs: ["cursor.usage"],
                migrationBaselineMetricIDs: ["cursor.usage"],
                defaultExpandedMetricIDs: ["cursor.requests"]
            )
        }

        // The user drags the still-disabled optional metric above the divider — an explicit placement
        // that consumes its expand-on-enable default.
        let store = args(defaults)
        XCTAssertTrue(store.reorderMetric(dragged: "cursor.requests", target: "cursor.usage", in: "cursor"))
        XCTAssertFalse(store.isMetricExpanded("cursor.requests"))

        // After a relaunch the consumed default must stay consumed — enabling it leaves it above the fold
        // (regression: the queue was recomputed each launch and resurrected the consumed entry).
        let reloaded = args(defaults)
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(reloaded.isMetricExpanded("cursor.requests"))
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
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))
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
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricExpanded("cursor.requests"))
    }

    func testCustomizeReorderDoesNotConsumeUnmovedDisabledExpandOnEnable() {
        let defaults = makeDefaults("CustomizePrimaryReorderKeepsUnmovedFallback")
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

        // Customize passes the full metric list (metricOrderWithDivider includes the disabled
        // cursor.requests before the divider) even when only reordering primary rows. The dragged
        // metric is cursor.today, not cursor.requests — so cursor.requests' below-caret default must
        // survive the reorder and still place it below the caret when later enabled.
        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.today",
            "cursor.usage",
            "cursor.requests",
            divider
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
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
            "codex.session", "codex.weekly", "codex.spark", "codex.sparkWeekly",
            "codex.credits", "codex.rateLimitResets",
            "codex.trend", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "devin").map(\.id), [
            "devin.daily", "devin.weekly", "devin.extra"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "grok").map(\.id), [
            "grok.creditsUsed", "grok.payAsYouGo",
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
            "grok.creditsUsed", "grok.trend",
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
        XCTAssertEqual(expandedByProvider["claude"], ["claude.sonnet", "claude.today", "claude.yesterday", "claude.last30"])
        XCTAssertEqual(primaryByProvider["codex"], ["codex.session", "codex.weekly", "codex.trend"])
        // Spark (the optional model-specific limits) leads the expanded section, before credits.
        XCTAssertEqual(expandedByProvider["codex"], [
            "codex.spark", "codex.sparkWeekly",
            "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(primaryByProvider["devin"], ["devin.daily", "devin.weekly"])
        XCTAssertEqual(expandedByProvider["devin"], ["devin.extra"])
        XCTAssertEqual(primaryByProvider["grok"], ["grok.creditsUsed", "grok.trend"])
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

    // MARK: - Expanded ("Shown on expand") membership

    func testSetMetricExpandedMovesMetricBelowDividerAndPersists() {
        let defaults = makeDefaults("ExpandMove")
        // Hermetic: start with nothing below the caret (independent of DefaultLayout's seeding).
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout", defaultExpandedMetricIDs: [])
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
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ExpandNoOp"), storageKey: "layout", defaultExpandedMetricIDs: [])
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
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

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
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

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
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
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
        // Only session + weekly enabled, both primary to start, so expanding both makes the whole
        // provider expanded — independent of DefaultLayout's seeding.
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("AllExpanded"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: []
        )
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

    // MARK: - Customize master/detail (L1 list + L2 detail)

    func testCustomizeProviderRowsIncludesAllProvidersRegardlessOfEnablement() {
        // Disable Codex; L1 must still list it (greyed), in the registry's provider order.
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("RowsIncludeDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        XCTAssertEqual(store.customizeProviderRows.map(\.id), MockData.providers.map(\.id))
        let codex = store.customizeProviderRows.first { $0.id == "codex" }
        XCTAssertNotNil(codex, "disabled provider stays visible in L1")
        XCTAssertFalse(codex?.isEnabled ?? true, "disabled provider row reports isEnabled false")
        XCTAssertTrue(store.customizeProviderRows.first { $0.id == "claude" }?.isEnabled ?? false)
    }

    func testCustomizeProviderRowsCarriesMetricAndPinnedCounts() {
        let store = makeStore("RowCounts")
        for row in store.customizeProviderRows {
            XCTAssertEqual(row.metricCount, MockData.descriptors(for: row.id).count)
            XCTAssertEqual(row.pinnedCount, store.pinnedCount(forProvider: row.id))
        }
    }

    func testCustomizeDetailReturnsMetricsEvenWhenDisabled() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailWhenDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        // customizeGroups drops the disabled provider; customizeDetail does not.
        XCTAssertNil(store.customizeGroups.first { $0.provider.id == "codex" })
        let detail = store.customizeDetail(for: "codex")
        XCTAssertNotNil(detail, "disabled provider still has a detail to render dimmed")
        XCTAssertEqual(detail?.metrics.map(\.id), store.orderedSupportedMetrics(for: "codex").map(\.id))
    }

    func testCustomizeDetailSplitsAcrossDivider() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailSplit"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        let detail = store.customizeDetail(for: "claude")
        XCTAssertEqual(detail?.expandedMetrics.map(\.id), ["claude.weekly"])
        XCTAssertEqual(detail?.alwaysShownMetrics.map(\.id), ["claude.session", "claude.extra", "claude.today"])
    }

    func testCustomizeDetailIsNilForUnknownProvider() {
        let store = makeStore("DetailUnknown")
        XCTAssertNil(store.customizeDetail(for: "nope"))
    }

    func testMetricCountMatchesRegistryDescriptors() {
        let store = makeStore("MetricCount")
        for id in MockData.providers.map(\.id) {
            XCTAssertEqual(store.metricCount(for: id), MockData.descriptors(for: id).count)
        }
        XCTAssertEqual(store.metricCount(for: "missing"), 0)
    }

    func testCustomizeProviderIDClearsWhenLeavingCustomize() {
        let store = makeStore("RouteClears")
        store.screen = .customize
        store.customizeProviderID = "claude"
        XCTAssertEqual(store.customizeProviderID, "claude")

        store.screen = .dashboard
        XCTAssertNil(store.customizeProviderID, "leaving Customize resets the L2 selection back to the list")

        // A direct jump to Settings also clears it — never strand a detail selection on another screen.
        store.screen = .customize
        store.customizeProviderID = "codex"
        store.screen = .settings
        XCTAssertNil(store.customizeProviderID)
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
