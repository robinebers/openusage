import XCTest
@testable import OpenUsage

@MainActor
final class LayoutPersistenceTests: XCTestCase {
    func testStartupRepairsUseCrashSafeDependencyOrder() throws {
        let order = LayoutPersistence.startupWriteOrder
        let placed = try XCTUnwrap(order.firstIndex(of: .placed))

        XCTAssertEqual(Set(order), Set(LayoutPersistenceField.allCases))
        XCTAssertEqual(order.count, LayoutPersistenceField.allCases.count)
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: .expandedMetrics)), placed)
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: .expandOnEnable)), placed)
        XCTAssertEqual(order.last, .seededDefaults)
    }

    func testLoadsEveryExistingKeyAndFormat() throws {
        let defaults = makeDefaults("LoadsExistingKeys")
        defaults.set(try JSONEncoder().encode([PlacedWidget(descriptorID: "claude.session")]), forKey: "layout")
        defaults.set(try JSONEncoder().encode(["cursor", "claude"]), forKey: "layout.providerOrder")
        defaults.set(
            try JSONEncoder().encode(["claude": ["claude.weekly", "claude.session"]]),
            forKey: "layout.metricOrderByProvider"
        )
        defaults.set(try JSONEncoder().encode(["claude.session"]), forKey: "layout.seededDefaults")
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set(["cursor.requests"], forKey: "layout.expandOnEnable")
        defaults.set(["claude"], forKey: "layout.expandedProviders")
        defaults.set(MenuBarStyle.bars.rawValue, forKey: "layout.menuBarStyle")

        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")

        XCTAssertTrue(persistence.loadPlaced().isPresent)
        XCTAssertTrue(persistence.loadSeededDefaults().isPresent)
        XCTAssertEqual(persistence.loadPlaced().value?.map(\.descriptorID), ["claude.session"])
        XCTAssertEqual(persistence.loadProviderOrder().value, ["cursor", "claude"])
        XCTAssertEqual(persistence.loadMetricOrder().value?["claude"], ["claude.weekly", "claude.session"])
        XCTAssertEqual(persistence.loadSeededDefaults().value, ["claude.session"])
        XCTAssertEqual(persistence.loadPins().value, ["claude.session"])
        XCTAssertEqual(persistence.loadExpandedMetrics().value, ["claude.weekly"])
        XCTAssertEqual(persistence.loadExpandOnEnable().value, ["cursor.requests"])
        XCTAssertEqual(persistence.loadExpandedProviders().value, ["claude"])
        XCTAssertEqual(persistence.loadMenuBarStyle(), .bars)
    }

    func testLoadsDistinguishMissingAndMalformedValues() {
        let defaults = makeDefaults("LoadState")
        defaults.set("not encoded data", forKey: "layout")
        defaults.set([42], forKey: "layout.menuBarPins")
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")

        XCTAssertTrue(persistence.loadPlaced().isPresent)
        XCTAssertNil(persistence.loadPlaced().value)
        XCTAssertTrue(persistence.loadPins().isPresent)
        XCTAssertNil(persistence.loadPins().value)
        XCTAssertFalse(persistence.loadProviderOrder().isPresent)
        XCTAssertNil(persistence.loadProviderOrder().value)
    }

    func testSavesEveryExistingKeyAndFormat() throws {
        let defaults = makeDefaults("SavesExistingKeys")
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")

        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveProviderOrder(["cursor", "claude"])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.session"]])
        persistence.saveSeededDefaults(["claude.session"])
        persistence.savePins(["claude.session"])
        persistence.saveExpandedMetrics(["claude.weekly"])
        persistence.saveExpandOnEnable(["cursor.requests"])
        persistence.saveExpandedProviders(["claude"])
        persistence.saveMenuBarStyle(.bars)

        XCTAssertEqual(try decode([PlacedWidget].self, key: "layout", defaults: defaults).map(\.descriptorID), ["claude.session"])
        XCTAssertEqual(try decode([String].self, key: "layout.providerOrder", defaults: defaults), ["cursor", "claude"])
        XCTAssertEqual(
            try decode([String: [String]].self, key: "layout.metricOrderByProvider", defaults: defaults)["claude"],
            ["claude.weekly", "claude.session"]
        )
        XCTAssertEqual(try decode([String].self, key: "layout.seededDefaults", defaults: defaults), ["claude.session"])
        XCTAssertEqual(Set(defaults.stringArray(forKey: "layout.menuBarPins") ?? []), ["claude.session"])
        XCTAssertEqual(Set(defaults.stringArray(forKey: "layout.expandedMetrics") ?? []), ["claude.weekly"])
        XCTAssertEqual(Set(defaults.stringArray(forKey: "layout.expandOnEnable") ?? []), ["cursor.requests"])
        XCTAssertEqual(Set(defaults.stringArray(forKey: "layout.expandedProviders") ?? []), ["claude"])
        XCTAssertEqual(defaults.string(forKey: "layout.menuBarStyle"), MenuBarStyle.bars.rawValue)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) throws -> T {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        return try JSONDecoder().decode(type, from: data)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.LayoutPersistence.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
