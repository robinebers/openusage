import XCTest
@testable import OpenUsage

/// Covers cancellation at the refresh fan-out boundary. Provider implementations intentionally return
/// user-facing error snapshots, so the store must distinguish a cancelled task from a real failure.
@MainActor
final class RefreshCancellationTests: XCTestCase {
    func testProviderTaskCancelledBeforeStartPerformsNoRefreshWork() async {
        let provider = Provider(id: "pre-cancel", displayName: "Pre-cancel", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor(
            id: "pre-cancel.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults()
        )

        // The test owns MainActor until `task.value`, so cancellation deterministically precedes the
        // child task's first instruction rather than racing its provider call.
        let task = Task { await store.refresh(providerID: provider.id, force: true) }
        task.cancel()
        let outcome = await task.value

        XCTAssertTrue(outcome == .skipped)
        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertFalse(store.refreshingProviderIDs.contains(provider.id))
    }

    func testCancelledRefreshAllRecordsNoFailureAndAllowsImmediateRetry() async {
        let started = expectation(description: "provider refresh started")
        let provider = Provider(
            id: "cancel-\(UUID().uuidString)",
            displayName: "Cancel",
            icon: .providerMark("claude")
        )
        let descriptor = WidgetDescriptor(
            id: "\(provider.id).session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CancelThenSucceedProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            onFirstRefresh: { started.fulfill() }
        )
        let defaults = makeUserDefaults()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )
        var outcomes: [WidgetDataStore.RefreshOutcome] = []
        store.onRefreshOutcome = { _, outcome, _, _ in outcomes.append(outcome) }

        let batch = Task { await store.refreshAll(force: true) }
        await fulfillment(of: [started], timeout: 1)
        batch.cancel()
        await batch.value

        XCTAssertFalse(store.refreshingProviderIDs.contains(provider.id))
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertNil(store.snapshots[provider.id])
        XCTAssertNil(cache.snapshot(providerID: provider.id))
        XCTAssertTrue(outcomes.isEmpty, "cancellation must not be recorded as provider telemetry")

        // A fresh task must run immediately; cancellation must not install the normal failure backoff.
        let retryOutcome = await store.refresh(providerID: provider.id)
        XCTAssertTrue(retryOutcome == .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertNotNil(store.snapshots[provider.id])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes.first == .refreshed)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "RefreshCancellationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CancelThenSucceedProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let onFirstRefresh: () -> Void
    private var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], onFirstRefresh: @escaping () -> Void) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.onFirstRefresh = onFirstRefresh
    }

    func refresh() async -> ProviderSnapshot {
        refreshCount += 1
        if refreshCount == 1 {
            onFirstRefresh()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Real providers similarly translate request cancellation into a friendly error snapshot.
                return ProviderSnapshot.error(provider: provider, message: "Cancelled request.")
            }
        }
        return ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)]
        )
    }
}
