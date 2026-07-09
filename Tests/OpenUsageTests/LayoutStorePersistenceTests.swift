import XCTest
@testable import OpenUsage

@MainActor
extension LayoutStoreTests {
    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = makeDefaults("EmptyLayout")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        for widget in store.placed {
            store.remove(widget.id)
        }

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.placed.isEmpty)
    }

    func testUnreadableStoredLayoutIsNotMistakenForFreshInstall() throws {
        let defaults = makeDefaults("UnreadableExistingLayout")
        defaults.set(Data("not valid layout data".utf8), forKey: "layout")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )

        XCTAssertFalse(
            store.expandedMetricIDs.contains("claude.weekly"),
            "present but damaged data is still an existing layout, so fresh-only defaults must stay off"
        )
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                [PlacedWidget].self,
                from: XCTUnwrap(defaults.data(forKey: "layout"))
            ),
            "the recovered default layout replaces unreadable storage instead of failing every launch"
        )
    }

    func testUnreadableSeedMarkerKeepsExistingUserBaseline() {
        let defaults = makeDefaults("UnreadableSeedMarker")
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
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricEnabled("cursor.requests"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
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
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.today"))
        // A metric the user already lived with stays always-shown.
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"))

        // The new expanded membership persists across reloads.
        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.today"]
        )
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("claude.today"))
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
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("cursor.requests"))
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
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        // After a relaunch the consumed default must stay consumed — enabling it leaves it above the fold
        // (regression: the queue was recomputed each launch and resurrected the consumed entry).
        let reloaded = args(defaults)
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
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
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
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

        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
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

        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

}
