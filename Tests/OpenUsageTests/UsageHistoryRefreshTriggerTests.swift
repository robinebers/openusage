import XCTest
@testable import OpenUsage

@MainActor
final class UsageHistoryRefreshTriggerTests: XCTestCase {
    func testBatchWritesOnceAndDirectManualRefreshWritesOnce() async {
        let first = HistoryTriggerRuntime(id: "first")
        let second = HistoryTriggerRuntime(id: "second")
        let defaults = makeDefaults()
        let store = WidgetDataStore(
            registry: WidgetRegistry(
                providers: [first.provider, second.provider],
                descriptors: first.widgetDescriptors + second.widgetDescriptors
            ),
            providers: [first, second],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        var writes = 0
        store.onLocalHistoryChanged = { writes += 1 }

        await store.refreshAll(force: true)
        XCTAssertEqual(writes, 1, "a concurrent provider batch publishes one history change")

        await store.refresh(providerID: first.provider.id, force: true)
        XCTAssertEqual(writes, 2, "a direct manual provider refresh publishes immediately")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "OpenUsageTests.HistoryTriggers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class HistoryTriggerRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]

    init(id: String) {
        provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        widgetDescriptors = []
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }

    func hasLocalCredentials() async -> Bool { true }
}
