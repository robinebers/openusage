import Foundation
import XCTest
@testable import OpenUsage

/// The per-provider refresh deadline (#1081). A provider whose `refresh()` never returns must not leave
/// the dashboard spinner turning for the rest of the session, the abandoned work must actually be
/// cancelled rather than left running, and a refresh that lands inside the deadline must be untouched.
@MainActor
final class RefreshTimeoutTests: XCTestCase {
    func testHungProviderRefreshFailsAndStopsTheSpinner() async {
        let (provider, descriptor) = makeProvider()
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty, "the spinner must stop when the deadline wins")
        XCTAssertEqual(store.errorMessage(for: provider.id)?.hasPrefix("Refresh timed out after"), true)
        // Same failure handling as any other error: the provider is negative-cached, so the next
        // non-forced pass backs off instead of re-probing a provider that just hung.
        let next = await store.refresh(providerID: provider.id)
        XCTAssertEqual(next, .backedOff)
    }

    func testHungProviderRefreshIsCancelledWhenTheDeadlineWins() async {
        let (provider, descriptor) = makeProvider()
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .failed)
        let cancelled = await waitUntil { runtime.wasCancelled }
        XCTAssertTrue(cancelled, "a refresh the store gave up on must be cancelled, or the hung work runs forever")
    }

    func testRefreshInsideTheDeadlineStillSucceeds() async {
        let (provider, descriptor) = makeProvider()
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertEqual(store.data(for: descriptor).used, 42)
    }

    private func makeProvider() -> (Provider, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return (provider, descriptor)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: ProviderRuntime,
        timeout: TimeInterval
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("refresh-timeout"),
            providerRefreshTimeout: timeout
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
