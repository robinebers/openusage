import XCTest
@testable import OpenUsage

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(state.expandedMetricIDs, ["claude.weekly"])
        XCTAssertEqual(
            state.persistencePlan.fieldsToWrite,
            [.seededDefaults, .expandedMetrics, .expandOnEnable]
        )
        XCTAssertEqual(state.persistencePlan.state.seededDefaults, ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.persistencePlan.state.expandedMetrics, ["claude.weekly"])
        XCTAssertEqual(state.persistencePlan.state.expandOnEnable, [])
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertEqual(state.persistencePlan.fieldsToWrite, [.seededDefaults, .expandOnEnable])
        XCTAssertEqual(state.persistencePlan.state.expandOnEnable, ["claude.weekly"])
        XCTAssertEqual(state.persistencePlan.state.seededDefaults, ["claude.session", "claude.weekly"])
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertEqual(state.persistencePlan.fieldsToWrite, [.expandOnEnable])
        XCTAssertEqual(state.persistencePlan.state.expandOnEnable, ["claude.weekly"])
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
