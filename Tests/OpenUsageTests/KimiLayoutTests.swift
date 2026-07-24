import XCTest
@testable import OpenUsage

/// Layout defaults for Kimi's two metrics. Uses the real provider's registry — `MockData` carries no
/// Kimi fixtures — with the real `DefaultLayout` seeds.
@MainActor
final class KimiLayoutTests: XCTestCase {

    func testFreshDefaultsEnablePinAndAlwaysShowBothMeters() {
        let store = makeStore("FreshDefaults")

        // Both metrics enabled, in declaration order.
        XCTAssertEqual(store.placed.map(\.descriptorID), ["kimi.session", "kimi.weekly"])

        // Both pinned — exactly the 2-per-provider cap, matching Claude/Codex Session+Weekly.
        XCTAssertEqual(store.pinnedMetricIDs, ["kimi.session", "kimi.weekly"])

        // Both above the fold: with nothing marked On Demand there is no caret section.
        let group = store.customizeGroups.first { $0.provider.id == "kimi" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [])
    }

    /// Kimi is absent from the migration baseline, so an existing install picks its defaults up once
    /// instead of the provider shipping invisibly off.
    func testExistingLayoutAutoSeedsBothMetricsOnce() {
        let defaults = makeDefaults("SeedForExistingUser")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .kimiOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("kimi.session"))
        XCTAssertTrue(store.isMetricEnabled("kimi.weekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("kimi.session"))
        XCTAssertFalse(store.expandedMetricIDs.contains("kimi.weekly"))
    }

    func testSavedPinsKeyIsRespectedExactly() {
        let defaults = makeDefaults("PinsPresent")
        saveStored([PlacedWidget(descriptorID: "kimi.session")], forKey: "layout", in: defaults)
        defaults.set(["kimi.weekly"], forKey: "layout.menuBarPins")

        let store = LayoutStore(registry: .kimiOnly, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.pinnedMetricIDs, ["kimi.weekly"],
                       "a user-saved pin set must not gain the new default pins")
    }

    func testDisablingAMetricDropsItFromTheCard() {
        let store = makeStore("DisableOne")

        store.setMetricEnabled("kimi.weekly", false)

        XCTAssertEqual(store.placed.map(\.descriptorID), ["kimi.session"])
        XCTAssertFalse(store.isMetricEnabled("kimi.weekly"))
    }

    // MARK: - Fixtures

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .kimiOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.KimiLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// A registry with just the live Kimi provider, so `DefaultLayout`'s seeds filter down to its two
    /// metrics.
    @MainActor
    static var kimiOnly: WidgetRegistry { .from([KimiProvider()]) }
}
