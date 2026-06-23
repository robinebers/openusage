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
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.add("claude.extra")
        XCTAssertTrue(store.isMetricEnabled("claude.extra"))

        guard let widget = store.placed.first(where: { $0.descriptorID == "claude.extra" }) else {
            return XCTFail("missing widget")
        }
        store.remove(widget.id)
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
    }

    func testPlanWidgetsAreNotRegisteredAsAddableMetrics() {
        let store = makeStore("Plans")
        XCTAssertFalse(store.availableToAdd.contains { PlanWidget.isPlan($0) })
    }

    func testTogglingMetricDoesNotChangeCustomizeOrder() {
        let store = makeStore("ToggleKeepsOrder")
        let before = store.orderedSupportedMetrics(for: "claude").map(\.id)
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), before)

        store.setMetricEnabled("claude.extra", false)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), before)
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

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = makeDefaults("DisabledMetricOrder")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        let original = store.orderedSupportedMetrics(for: "claude").map(\.id)
        guard let first = original.first else { return XCTFail("missing Claude metrics") }
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.reorderMetric(dragged: "claude.extra", target: first, in: "claude")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
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
