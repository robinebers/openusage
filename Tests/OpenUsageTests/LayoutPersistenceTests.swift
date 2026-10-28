import XCTest
@testable import OpenUsage

@MainActor
final class LayoutPersistenceTests: XCTestCase {
    func testLoadsEveryExistingKeyAndFormat() throws {
        let defaults = isolatedDefaults()
        defaults.set(["claude.session"], forKey: "layout.hiddenMetrics")
        defaults.set(try JSONEncoder().encode(["cursor", "claude"]), forKey: "layout.providerOrder")
        defaults.set(
            try JSONEncoder().encode(["claude": ["claude.weekly", "claude.session"]]),
            forKey: "layout.metricOrderByProvider"
        )
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")

        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")

        XCTAssertEqual(persistence.loadHidden(), ["claude.session"])
        XCTAssertEqual(persistence.loadProviderOrder(), ["cursor", "claude"])
        XCTAssertEqual(persistence.loadMetricOrder()?["claude"], ["claude.weekly", "claude.session"])
        XCTAssertEqual(persistence.loadPins(), ["claude.session"])
    }

    func testSavesEveryExistingKeyAndFormat() throws {
        let defaults = isolatedDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")

        persistence.saveHidden(["claude.weekly", "claude.session"])
        persistence.saveProviderOrder(["cursor", "claude"])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.session"]])
        persistence.savePins(["claude.session"])

        XCTAssertEqual(defaults.stringArray(forKey: "layout.hiddenMetrics"), ["claude.session", "claude.weekly"])
        XCTAssertEqual(try decode([String].self, key: "layout.providerOrder", defaults: defaults), ["cursor", "claude"])
        XCTAssertEqual(
            try decode([String: [String]].self, key: "layout.metricOrderByProvider", defaults: defaults)["claude"],
            ["claude.weekly", "claude.session"]
        )
        XCTAssertEqual(Set(defaults.stringArray(forKey: "layout.menuBarPins") ?? []), ["claude.session"])
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) throws -> T {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        return try JSONDecoder().decode(type, from: data)
    }

}
