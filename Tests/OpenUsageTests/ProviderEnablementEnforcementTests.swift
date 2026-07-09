import XCTest
@testable import OpenUsage

/// Covers that the enable/disable choice is actually *enforced* everywhere a provider is consulted:
/// the refresh loop, the menu-bar value, and the dashboard / Customize layout.
@MainActor
final class ProviderEnablementEnforcementTests: XCTestCase {
    // MARK: - WidgetDataStore refresh

    func testDisabledProviderIsNotRefreshedWhileEnabledOneIs() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("refresh-enablement"))
        enablement.setEnabled(false, for: "codex")

        let claude = makeRuntime("claude", used: 30)
        let codex = makeRuntime("codex", used: 80)
        let suite = makeDefaults("refresh-store")
        let store = WidgetDataStore(
            registry: WidgetRegistry(
                providers: [claude.provider, codex.provider],
                descriptors: [claude.descriptor, codex.descriptor]
            ),
            providers: [claude.runtime, codex.runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: suite,
            isProviderEnabled: { enablement.isEnabled($0) }
        )

        await store.refreshAll()

        XCTAssertEqual(claude.runtime.refreshCount, 1)
        XCTAssertEqual(codex.runtime.refreshCount, 0)
        XCTAssertNotNil(store.snapshots["claude"])
        XCTAssertNil(store.snapshots["codex"])

        // A direct refresh of a disabled provider is also a no-op.
        await store.refresh(providerID: "codex")
        XCTAssertEqual(codex.runtime.refreshCount, 0)
        XCTAssertNil(store.snapshots["codex"])
    }

    // Tray ownership by layout order + disabled-provider exclusion is exercised on the real tray path
    // (LayoutStore.pinnedGroups + MenuBarContentBuilder) in MenuBarPinTests / MenuBarContentTests.

    // MARK: - Layout

    func testVisiblePlacedAndCustomizeGroupsExcludeDisabledProviderThenRestore() {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("layout-enablement"))
        let layout = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("layout-store"),
            storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )

        // All enabled => visiblePlaced is byte-for-byte the full placed list.
        XCTAssertEqual(layout.visiblePlaced, layout.placed)
        XCTAssertTrue(layout.customizeGroups.contains { $0.provider.id == "cursor" })

        enablement.setEnabled(false, for: "cursor")

        XCTAssertFalse(layout.visiblePlaced.contains { $0.descriptorID.hasPrefix("cursor.") })
        XCTAssertTrue(layout.visiblePlaced.contains { $0.descriptorID.hasPrefix("claude.") })
        // Disabling hides but does not delete: the Cursor tiles are still parked in `placed`.
        XCTAssertTrue(layout.placed.contains { $0.descriptorID.hasPrefix("cursor.") })
        XCTAssertFalse(layout.customizeGroups.contains { $0.provider.id == "cursor" })
        XCTAssertEqual(layout.customizeProviderRows.first { $0.id == "cursor" }?.isEnabled, false)

        enablement.setEnabled(true, for: "cursor")

        XCTAssertEqual(layout.visiblePlaced, layout.placed)
        XCTAssertTrue(layout.customizeGroups.contains { $0.provider.id == "cursor" })
        XCTAssertEqual(layout.customizeProviderRows.first { $0.id == "cursor" }?.isEnabled, true)
    }

    // MARK: - Helpers

    private struct Fixture {
        let provider: Provider
        let descriptor: WidgetDescriptor
        let runtime: CountingProviderRuntime
    }

    private func makeRuntime(_ id: String, used: Double) -> Fixture {
        let provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        let descriptor = WidgetDescriptor(
            id: "\(id).session",
            providerID: id,
            metricLabel: "Session",
            sample: WidgetData(
                title: "Session",
                icon: provider.icon,
                kind: .percent,
                used: used,
                limit: 100,
                displayMode: .used
            )
        )
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)]
            )
        )
        return Fixture(provider: provider, descriptor: descriptor, runtime: runtime)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.EnablementEnforce.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
