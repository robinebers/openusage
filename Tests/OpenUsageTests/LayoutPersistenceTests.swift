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
            pinnedMetricIDs: ["claude@1.session"],
            seededProviderIDs: ["claude@1", "cursor@2"]
        )

        LayoutPersistence(defaults: defaults).save(state)

        XCTAssertEqual(LayoutPersistence(defaults: defaults).load(), state)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("openusage.layout") }, ["openusage.layout.v2"])
    }
}
