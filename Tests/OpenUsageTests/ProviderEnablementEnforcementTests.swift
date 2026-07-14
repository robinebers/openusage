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

    func testDisablingProviderRemovesPeerHistoryButKeepsLocalSnapshot() async throws {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("history-enablement"))
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let historyDescriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "From test logs"
        )
        let descriptors = [
            WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
                scope: historyDescriptor.scope,
                estimatedCost: historyDescriptor.estimatedCost,
                sourceNote: historyDescriptor.sourceNote
            )
        ] + WidgetDescriptor.spendTiles(provider: provider)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 12))!
        let localHistory = history(tokens: 100, cost: 1, now: now)
        let localSnapshot = UsageHistorySnapshotRenderer.render(
            local: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                usageHistory: localHistory
            ),
            history: localHistory,
            descriptor: historyDescriptor,
            now: now,
            combined: false
        )
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: localSnapshot
        )
        let defaults = makeDefaults("history-store")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) },
            now: { now }
        )
        enablement.onChange = { store.providerEnablementDidChange() }

        await store.refreshAll(force: true)
        store.setPeerHistoryDocuments([
            UsageHistoryDocument(
                deviceID: "peer",
                deviceName: "Peer Mac",
                updatedAt: now,
                providers: [provider.id: history(tokens: 200, cost: 2, now: now)]
            )
        ], ownDeviceID: "this-mac")
        XCTAssertEqual(try spendTokens(store.snapshots[provider.id], label: "Today"), 300)

        enablement.setEnabled(false, for: provider.id)

        XCTAssertEqual(try spendTokens(store.snapshots[provider.id], label: "Today"), 100)
        XCTAssertNotNil(store.localSnapshots[provider.id])
        XCTAssertNil(store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac").providers[provider.id])
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

    private func history(tokens: Int, cost: Double, now: Date) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(
                date: DailyUsageAccumulator.dayKey(from: now),
                totalTokens: tokens,
                costUSD: cost
            )
        ]))
    }

    private func spendTokens(_ snapshot: ProviderSnapshot?, label: String) throws -> Double {
        guard case .values(_, let values, _, _, _, _) = try XCTUnwrap(snapshot?.line(label: label)) else {
            throw NSError(domain: "ProviderEnablementEnforcementTests", code: 1)
        }
        return try XCTUnwrap(values.first { $0.kind == .count }?.number)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.EnablementEnforce.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
