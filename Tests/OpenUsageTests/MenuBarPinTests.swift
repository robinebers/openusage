import XCTest
@testable import OpenUsage

/// Covers the menu-bar pin model on `LayoutStore`: the ≤2-per-provider rendering cap, denial
/// reasons/notices, order derivation from the saved layout order, and persistence across relaunch.
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

        // An already-pinned id can still be pinned, so its toggle can unpin it.
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

        // A denied click surfaces the reason as the transient footer notice and bumps the shake
        // trigger every time, so repeat clicks re-shake even while the text is unchanged.
        XCTAssertNil(store.pinLimitNotice)
        XCTAssertEqual(store.pinNoticeShakeTrigger, 0)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinLimitNotice, "Up to 2 stars per provider")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 1)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 2)
    }

    func testPinnedGroupsFollowCustomizeOrder() {
        let store = makeStore()
        // Pin out of order; expect provider order (a before b) and metric order (m1 before m2).
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
        defaults.set(["a.m1", "ghost.metric"], forKey: "layout.menuBarPins")
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.isPinned("a.m1"))
        XCTAssertFalse(store.isPinned("ghost.metric"))
    }

    // MARK: - Fixtures

    private func makeStore() -> LayoutStore {
        makeStore(defaults: isolatedDefaults())
    }

    /// Every metric starts shown, since only a shown metric can keep a star.
    private func makeStore(defaults: UserDefaults) -> LayoutStore {
        let registry = makeRegistry()
        return LayoutStore(registry: registry, defaults: defaults, storageKey: "layout",
                           defaultMetricIDs: registry.descriptors.map(\.id))
    }

    /// Two providers, each with three percent metrics, are sufficient to exercise provider-local caps.
    private func makeRegistry() -> WidgetRegistry {
        let providers = ["a", "b"].map { id in
            Provider(id: id, displayName: id.uppercased(), icon: "cursor")
        }
        let descriptors = providers.flatMap { provider in
            (1...3).map { n in metric(provider, id: "\(provider.id).m\(n)", label: "M\(n)") }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func metric(_ provider: Provider, id: String, label: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: label,
            sample: WidgetData(
                title: label,
                icon: provider.icon,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

}
