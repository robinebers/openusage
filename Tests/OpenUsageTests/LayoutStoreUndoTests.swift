import XCTest
@testable import OpenUsage

@MainActor
extension LayoutStoreTests {
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
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"))

        XCTAssertTrue(moveMetric("claude.session", expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.session"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"), "undo moves the metric back above the caret")
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
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("UndoDirectRemove"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.weekly"]
        )
        guard let widget = store.placed.first(where: { $0.descriptorID == "claude.weekly" }) else {
            return XCTFail("metric was not placed")
        }

        store.remove(widget.id)

        XCTAssertFalse(store.canUndo)
    }

}
