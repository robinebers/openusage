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
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
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
        XCTAssertFalse(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
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
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertNil(state.seededDefaultsToPersist)
    }

    func testDisabledInstanceDefaultStaysOffAcrossSuppressedLaunch() {
        let (_, defaults) = makePersistence("SuppressedInstance")
        let storageKey = "layout"
        let baseID = "claude.session"
        let instanceID = "claude@f15456b0.session"
        let fullRegistry = makeRegistry(includeInstance: true)

        let firstLaunch = LayoutStore(
            registry: fullRegistry,
            defaults: defaults,
            storageKey: storageKey,
            defaultMetricIDs: [baseID, instanceID],
            migrationBaselineMetricIDs: [baseID, instanceID],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )
        firstLaunch.setMetricEnabled(instanceID, false)
        XCTAssertFalse(firstLaunch.placed.contains { $0.descriptorID == instanceID })

        // The account is temporarily the default login, so its instance runtime and descriptors are
        // absent for one launch. This launch must not erase the "already offered" marker.
        _ = LayoutStore(
            registry: makeRegistry(includeInstance: false),
            defaults: defaults,
            storageKey: storageKey,
            defaultMetricIDs: [baseID],
            migrationBaselineMetricIDs: [baseID],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )

        let returnedLaunch = LayoutStore(
            registry: fullRegistry,
            defaults: defaults,
            storageKey: storageKey,
            defaultMetricIDs: [baseID, instanceID],
            migrationBaselineMetricIDs: [baseID, instanceID],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )
        XCTAssertFalse(
            returnedLaunch.placed.contains { $0.descriptorID == instanceID },
            "returning an instance must not re-enable a default metric the user turned off"
        )
    }

    func testSuppressedInstanceLayoutStateSurvivesUnrelatedWritesAndReturns() {
        let (persistence, defaults) = makePersistence("SuppressedInstanceLayout")
        let storageKey = "layout"
        let instanceProviderID = "claude@f15456b0"
        let baseSession = "claude.session"
        let baseWeekly = "claude.weekly"
        let instanceSession = "\(instanceProviderID).session"
        let instanceWeekly = "\(instanceProviderID).weekly"

        persistence.savePlaced([
            PlacedWidget(descriptorID: baseSession),
            PlacedWidget(descriptorID: instanceSession),
        ])
        persistence.saveProviderOrder(["claude", instanceProviderID])
        persistence.saveMetricOrder([
            "claude": [baseSession, baseWeekly],
            instanceProviderID: [instanceWeekly, instanceSession],
        ])
        persistence.savePins([instanceSession])
        persistence.saveExpandedMetrics([instanceSession])
        persistence.saveExpandedProviders([instanceProviderID])
        persistence.saveExpandOnEnable([instanceWeekly])
        persistence.saveSeededDefaults([])

        // The instance is temporarily absent. Exercise an unrelated write for every layout collection;
        // each write serializes the whole collection and therefore used to erase the hidden instance.
        let suppressedLaunch = LayoutStore(
            registry: makeRegistry(includeInstance: false),
            defaults: defaults,
            storageKey: storageKey,
            defaultMetricIDs: [],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )
        suppressedLaunch.setMetricEnabled(baseWeekly, true)
        suppressedLaunch.setPinned(true, for: baseSession)
        suppressedLaunch.expandedMetricIDs.insert(baseWeekly)
        suppressedLaunch.persistExpanded()
        XCTAssertTrue(suppressedLaunch.setProviderExpanded(true, for: "claude"))
        suppressedLaunch.defaultExpandedOnEnableIDs.insert(baseWeekly)
        suppressedLaunch.persistExpandOnEnable()
        XCTAssertTrue(
            suppressedLaunch.reorderMetric(
                dragged: baseWeekly,
                target: baseSession,
                in: "claude"
            )
        )
        suppressedLaunch.providerOrder = ["claude", instanceProviderID]
        suppressedLaunch.persistProviderOrder()

        let returnedLaunch = LayoutStore(
            registry: makeRegistry(includeInstance: true),
            defaults: defaults,
            storageKey: storageKey,
            defaultMetricIDs: [],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )

        XCTAssertTrue(returnedLaunch.isMetricEnabled(instanceSession))
        XCTAssertTrue(returnedLaunch.isPinned(instanceSession))
        XCTAssertTrue(returnedLaunch.expandedMetricIDs.contains(instanceSession))
        XCTAssertTrue(returnedLaunch.isProviderExpanded(instanceProviderID))
        XCTAssertTrue(returnedLaunch.defaultExpandedOnEnableIDs.contains(instanceWeekly))
        XCTAssertEqual(returnedLaunch.metricOrder(for: instanceProviderID), [instanceWeekly, instanceSession])
        XCTAssertEqual(returnedLaunch.providerOrder, ["claude", instanceProviderID])
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makeRegistry(includeInstance: Bool) -> WidgetRegistry {
        let base = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let instance = Provider(
            id: "claude@f15456b0",
            displayName: "Claude 2",
            icon: .providerMark("claude")
        )
        let providers = includeInstance ? [base, instance] : [base]
        let descriptors = providers.flatMap { provider in
            ["session", "weekly"].map { metric in
                WidgetDescriptor(
                    id: "\(provider.id).\(metric)",
                    providerID: provider.id,
                    metricLabel: metric.capitalized,
                    sample: WidgetData(
                        title: metric.capitalized,
                        icon: provider.icon,
                        kind: .percent,
                        used: 0,
                        limit: 100
                    )
                )
            }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
