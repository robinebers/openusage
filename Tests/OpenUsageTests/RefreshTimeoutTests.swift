import Foundation
import XCTest
@testable import OpenUsage

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
        let runtime = StubRuntime(
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
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "session",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100)
        )
        return (provider, descriptor)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: ProviderRuntime,
        timeout: TimeInterval
    ) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        return WidgetDataStore.forTesting([runtime], defaults: defaults, providerRefreshTimeout: timeout)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

}
