import XCTest
@testable import OpenUsage

@MainActor
extension LayoutStoreTests {
    // MARK: - Customize master/detail (L1 list + L2 detail)

    func testCustomizeProviderRowsIncludesAllProvidersRegardlessOfEnablement() {
        // Disable Codex; L1 must still list it (greyed), in the registry's provider order.
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("RowsIncludeDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        XCTAssertEqual(store.customizeProviderRows.map(\.id), MockData.providers.map(\.id))
        let codex = store.customizeProviderRows.first { $0.id == "codex" }
        XCTAssertNotNil(codex, "disabled provider stays visible in L1")
        XCTAssertFalse(codex?.isEnabled ?? true, "disabled provider row reports isEnabled false")
        XCTAssertTrue(store.customizeProviderRows.first { $0.id == "claude" }?.isEnabled ?? false)
    }

    func testCustomizeProviderRowsCarriesMetricAndPinnedCounts() {
        let store = makeStore("RowCounts")
        for row in store.customizeProviderRows {
            XCTAssertEqual(row.metricCount, MockData.descriptors(for: row.id).count)
            XCTAssertEqual(row.pinnedCount, store.pinnedCount(forProvider: row.id))
        }
    }

    func testCustomizeDetailReturnsMetricsEvenWhenDisabled() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailWhenDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        // customizeGroups drops the disabled provider; customizeDetail does not.
        XCTAssertNil(store.customizeGroups.first { $0.provider.id == "codex" })
        let detail = store.customizeDetail(for: "codex")
        XCTAssertNotNil(detail, "disabled provider still has a detail to render dimmed")
        XCTAssertEqual(detail?.metrics.map(\.id), store.orderedSupportedMetrics(for: "codex").map(\.id))
    }

    func testCustomizeDetailSplitsAcrossDivider() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailSplit"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        let detail = store.customizeDetail(for: "claude")
        XCTAssertEqual(detail?.expandedMetrics.map(\.id), ["claude.weekly"])
        XCTAssertEqual(detail?.alwaysShownMetrics.map(\.id), ["claude.session", "claude.extra", "claude.today"])
    }

    func testCustomizeDetailIsNilForUnknownProvider() {
        let store = makeStore("DetailUnknown")
        XCTAssertNil(store.customizeDetail(for: "nope"))
    }

    func testMetricCountMatchesRegistryDescriptors() {
        let store = makeStore("MetricCount")
        for id in MockData.providers.map(\.id) {
            XCTAssertEqual(store.metricCount(for: id), MockData.descriptors(for: id).count)
        }
        XCTAssertEqual(store.metricCount(for: "missing"), 0)
    }

    func testCustomizeProviderIDClearsWhenLeavingCustomize() {
        let store = makeStore("RouteClears")
        store.screen = .customize
        store.customizeProviderID = "claude"
        XCTAssertEqual(store.customizeProviderID, "claude")

        store.screen = .dashboard
        XCTAssertNil(store.customizeProviderID, "leaving Customize resets the L2 selection back to the list")

        // A direct jump to Settings also clears it — never strand a detail selection on another screen.
        store.screen = .customize
        store.customizeProviderID = "codex"
        store.screen = .settings
        XCTAssertNil(store.customizeProviderID)
    }

}
