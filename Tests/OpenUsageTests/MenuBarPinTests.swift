import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarPinTests: XCTestCase {
    func testNoPinsByDefault() {
        let store = makeStore()
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
        XCTAssertTrue(store.pinnedGroups.isEmpty)
    }

    func testPinUnpinPersistsAcrossReload() {
        let defaults = isolatedDefaults()
        let store = makeStore(defaults: defaults)

        store.setPinned(true, for: "a.m1")
        XCTAssertTrue(store.isPinned("a.m1"))

        let reloaded = makeStore(defaults: defaults)
        XCTAssertTrue(reloaded.isPinned("a.m1"))

        reloaded.setPinned(false, for: "a.m1")
        let reloadedAgain = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedAgain.isPinned("a.m1"))
    }

    func testPerProviderCapBlocksThirdPinUntilSlotIsFreed() {
        let store = makeStore()
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")

        XCTAssertFalse(store.canPin("a.m3"))
        store.setPinned(true, for: "a.m3")
        XCTAssertFalse(store.isPinned("a.m3"))
        XCTAssertEqual(store.pinnedCount(forProvider: "a"), 2)

        XCTAssertTrue(store.canPin("a.m1"))

        store.setPinned(false, for: "a.m1")
        XCTAssertTrue(store.canPin("a.m3"))
    }

    func testEachProviderCanPinUpToTwo() {
        let store = makeStore()
        for provider in ["a", "b"] {
            store.setPinned(true, for: "\(provider).m1")
            store.setPinned(true, for: "\(provider).m2")
            XCTAssertFalse(store.canPin("\(provider).m3"))
        }
        XCTAssertEqual(store.pinnedMetricIDs.count, 4)
    }

    func testPinDenialReasonsAndFooterNotice() {
        let store = makeStore()
        XCTAssertNil(store.pinDenialReason("a.m1"))

        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")
        XCTAssertEqual(store.pinDenialReason("a.m3"), "Up to 2 stars per provider")
        XCTAssertNil(store.pinDenialReason("b.m1"))

        let popover = PopoverState()
        XCTAssertNil(popover.pinNotice.value)
        XCTAssertEqual(popover.pinNotice.trigger, 0)
        popover.pinNotice.present(store.pinDenialReason("a.m3"))
        XCTAssertEqual(popover.pinNotice.value, "Up to 2 stars per provider")
        XCTAssertEqual(popover.pinNotice.trigger, 1)
        popover.pinNotice.present(store.pinDenialReason("a.m3"))
        XCTAssertEqual(popover.pinNotice.trigger, 2)
    }

    func testPinnedGroupsFollowCustomizeOrder() {
        let store = makeStore()
        store.setPinned(true, for: "b.m2")
        store.setPinned(true, for: "a.m2")
        store.setPinned(true, for: "a.m1")

        XCTAssertEqual(store.pinnedGroups.flatMap { $0.metrics.map(\.id) }, ["a.m1", "a.m2", "b.m2"])
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["a", "b"])
    }

    func testAllProviderPinsAppearInGroups() {
        let store = makeStore(defaults: isolatedDefaults())
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "b.m1")

        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["a", "b"])
        XCTAssertTrue(store.isPinned("a.m1"))
    }

    func testInvalidPinnedIDsDroppedOnLoad() {
        let defaults = isolatedDefaults()
        LayoutPersistence(defaults: defaults).save(LayoutState(pinnedMetricIDs: ["a.m1", "ghost.metric"]))
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.isPinned("a.m1"))
        XCTAssertFalse(store.isPinned("ghost.metric"))
    }

    private func makeStore() -> LayoutStore {
        makeStore(defaults: isolatedDefaults())
    }

    private func makeStore(defaults: UserDefaults) -> LayoutStore {
        LayoutStore(registry: makeRegistry(), defaults: defaults)
    }

    private func makeRegistry() -> WidgetRegistry {
        let providers = ["a", "b"].map { id in
            Provider(id: id, kind: id == "a" ? .claude : .codex)
        }
        let descriptors = providers.flatMap { provider in
            (1...3).map { n in metric(provider, key: "m\(n)", label: "M\(n)") }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func metric(_ provider: Provider, key: String, label: String) -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider,
            key: key,
            metricLabel: label,
            sample: WidgetData(
                title: label,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

}
