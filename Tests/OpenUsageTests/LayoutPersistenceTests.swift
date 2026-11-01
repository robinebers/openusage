import XCTest
@testable import OpenUsage

@MainActor
final class LayoutPersistenceTests: XCTestCase {
    func testSavesTheWholeLayoutUnderOneKey() {
        let defaults = isolatedDefaults()
        let state = LayoutState(
            hiddenMetricIDs: ["claude@1.extra"],
            providerOrder: ["cursor@2", "claude@1"],
            metricOrderByProvider: ["claude@1": ["claude@1.weekly", "claude@1.session"]],
            seededProviderIDs: ["claude@1", "cursor@2"]
        )

        LayoutPersistence(defaults: defaults).save(state)

        XCTAssertEqual(LayoutPersistence(defaults: defaults).load(), state)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("openusage.layout") }, ["openusage.layout.v2"])
    }

    func testALayoutWithStarsAndHiddenMetricsKeepsItsHiddenMetrics() throws {
        let defaults = isolatedDefaults()
        let saved: [String: Any] = [
            "hiddenMetricIDs": ["claude.weekly", "claude.extra"],
            "pinnedMetricIDs": ["claude.session", "codex.session"],
            "providerOrder": ["codex", "claude", "cursor"],
            "metricOrderByProvider": ["claude": ["claude.today", "claude.session"]],
            "seededProviderIDs": ["claude", "codex", "cursor"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: LayoutPersistence.key)

        let store = LayoutStore(registry: .mock, defaults: defaults)

        XCTAssertEqual(store.orderedProviders().map(\.id), ["codex", "claude", "cursor"], "the provider order survives")
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").prefix(2).map(\.id), ["claude.today", "claude.session"], "the metric order survives")
        XCTAssertEqual(Set(MockData.descriptors.map(\.id)).subtracting(store.visibleDescriptors.map(\.id)), ["claude.weekly", "claude.extra"],
                       "a metric saved as hidden stays hidden")
    }

    func testALayoutSavedWithoutHiddenMetricsStillLoads() throws {
        let defaults = isolatedDefaults()
        let saved: [String: Any] = [
            "providerOrder": ["codex", "claude", "cursor"],
            "metricOrderByProvider": ["claude": ["claude.today", "claude.session"]],
            "seededProviderIDs": ["claude", "codex", "cursor"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: LayoutPersistence.key)

        let store = LayoutStore(registry: .mock, defaults: defaults)

        XCTAssertEqual(store.orderedProviders().map(\.id), ["codex", "claude", "cursor"])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").prefix(2).map(\.id), ["claude.today", "claude.session"])
        XCTAssertEqual(Set(store.visibleDescriptors.map(\.id)), Set(MockData.descriptors.map(\.id)))
    }
}
