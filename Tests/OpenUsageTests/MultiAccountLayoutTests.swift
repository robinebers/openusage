import XCTest
@testable import OpenUsage

/// Layout behavior specific to extra accounts: one-time seeding (no resurrection of disabled metrics)
/// and duplicate-account hiding driven by the injected `accountEmailLookup`.
@MainActor
final class MultiAccountLayoutTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "MultiAccountLayoutTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A base provider ("claude") plus one extra account ("claude@work"), each with the same two metrics.
    private func makeRegistry() -> WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@work", displayName: "Claude · Work", icon: .providerMark("claude"))
        func metric(_ id: String, _ provider: Provider) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id, providerID: provider.id, metricLabel: "Metric",
                sample: WidgetData(title: "Metric", icon: provider.icon, kind: .percent, used: 0, limit: 100)
            )
        }
        return WidgetRegistry(
            providers: [claude, work],
            descriptors: [
                metric("claude.session", claude), metric("claude.weekly", claude),
                metric("claude@work.session", work), metric("claude@work.weekly", work)
            ]
        )
    }

    /// Pre-save a layout with the base account's two metrics placed, so seeding has something to mirror.
    private func seedBaseLayout(_ defaults: UserDefaults) {
        let placed = [PlacedWidget(descriptorID: "claude.session"), PlacedWidget(descriptorID: "claude.weekly")]
        defaults.set(try! JSONEncoder().encode(placed), forKey: "layout")
    }

    func testNewAccountSeedsMirroringBase() {
        let defaults = makeDefaults("Seed")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "claude@work.session" })
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "claude@work.weekly" })
    }

    /// Regression: disabling every metric of an extra account must stay disabled across a relaunch — the
    /// old auto-place re-ran for any unplaced account and resurrected them.
    func testDisablingAllAccountMetricsIsNotResurrectedOnReload() {
        let defaults = makeDefaults("NoResurrect")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        for widget in store.placed where widget.descriptorID.hasPrefix("claude@work.") {
            store.remove(widget.id)
        }
        XCTAssertFalse(store.placed.contains { $0.descriptorID.hasPrefix("claude@work.") })

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.placed.contains { $0.descriptorID.hasPrefix("claude@work.") })
    }

    func testDuplicateEmailAccountHiddenFromDashboardAndCustomize() {
        let defaults = makeDefaults("Dedup")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.accountEmailLookup = { ($0 == "claude" || $0 == "claude@work") ? "same@example.com" : nil }

        XCTAssertFalse(store.visiblePlaced.contains { $0.descriptorID.hasPrefix("claude@work.") })
        XCTAssertFalse(store.customizeGroups.contains { $0.provider.id == "claude@work" })
        // The first occurrence (the default login) stays visible.
        XCTAssertTrue(store.visiblePlaced.contains { $0.descriptorID == "claude.session" })
    }

    func testDistinctEmailAccountsBothVisible() {
        let defaults = makeDefaults("Distinct")
        seedBaseLayout(defaults)
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.accountEmailLookup = { $0 == "claude" ? "a@example.com" : ($0 == "claude@work" ? "b@example.com" : nil) }

        XCTAssertTrue(store.visiblePlaced.contains { $0.descriptorID.hasPrefix("claude@work.") })
        XCTAssertTrue(store.customizeGroups.contains { $0.provider.id == "claude@work" })
    }
}
