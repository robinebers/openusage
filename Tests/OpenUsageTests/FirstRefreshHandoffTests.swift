import XCTest
@testable import OpenUsage

@MainActor
final class FirstRefreshHandoffTests: XCTestCase {
    func testDashboardUsesFirstRefreshWithoutCallingProviderAgain() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let snapshot = ProviderSnapshot.make(provider: provider, plan: "Plan", lines: [.text(label: "Status", value: "Ready")], refreshedAt: Date())
        let runtime = CountingProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot)
        let suite = "FirstRefreshHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults)
        store.adoptFirstRefresh(snapshot)
        XCTAssertEqual(store.snapshots["test"], snapshot)
        let result = await store.refresh(providerID: "test")
        XCTAssertEqual(result, .cacheHit)
        XCTAssertEqual(runtime.refreshCount, 0)
    }

    func testNetworkFailureIsRetainedWithoutAnImmediateRetry() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let snapshot = ProviderSnapshot.error(provider: provider, message: "Offline", category: .network)
        let runtime = CountingProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot)
        let suite = "FirstRefreshHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults)
        store.adoptFirstRefresh(snapshot)
        XCTAssertEqual(store.errorMessage(for: "test"), "Offline")
        let result = await store.refresh(providerID: "test")
        XCTAssertEqual(result, .backedOff)
        XCTAssertEqual(runtime.refreshCount, 0)
    }
}
