import XCTest
@testable import OpenUsage

/// A manual refresh (⌘R, the footer, the Refresh menu items) asks each account at most once every 30
/// seconds, so mashing ⌘R doesn't hammer a provider; after that it fetches even inside the cache interval.
@MainActor
final class ManualRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMashingRefreshAsksEachAccountOncePerThirtySeconds() async {
        let clock = TestClock(start)
        let (store, runtimes) = makeStore(ids: ["a", "b"], clock: clock)

        await store.refreshManually()
        XCTAssertEqual(runtimes.map(\.refreshCount), [1, 1])
        for seconds in [1, 10, 29] {
            clock.set(start.addingTimeInterval(TimeInterval(seconds)))
            await store.refreshManually()
        }
        XCTAssertEqual(runtimes.map(\.refreshCount), [1, 1], "nothing is asked again inside 30 seconds")

        clock.set(start.addingTimeInterval(30))
        await store.refreshManually()
        XCTAssertEqual(runtimes.map(\.refreshCount), [2, 2], "after 30 seconds a manual refresh skips the cache")
    }

    func testTheMinimumIsPerAccount() async {
        let clock = TestClock(start)
        let (store, runtimes) = makeStore(ids: ["a", "b"], clock: clock)

        await store.refreshManually(providerIDs: ["a"])
        clock.set(start.addingTimeInterval(5))
        await store.refreshManually()
        XCTAssertEqual(runtimes.map(\.refreshCount), [1, 1], "b had not been fetched, so it still refreshes")
    }

    func testAScheduledFetchCountsTowardTheMinimum() async {
        let clock = TestClock(start)
        let (store, runtimes) = makeStore(ids: ["a"], clock: clock)

        await store.refreshAll()
        clock.set(start.addingTimeInterval(10))
        await store.refreshManually()
        XCTAssertEqual(runtimes[0].refreshCount, 1)
    }

    // MARK: - Helpers

    private func makeStore(ids: [String], clock: TestClock) -> (WidgetDataStore, [StubRuntime]) {
        let runtimes = ids.map { id in
            let provider = Provider(id: id, displayName: id, icon: "codex")
            let descriptor = WidgetDescriptor(
                id: "\(id).weekly", providerID: id, metricLabel: "Weekly quota",
                sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
            )
            return StubRuntime(
                provider: provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: id, displayName: id,
                    lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
                    refreshedAt: start
                )
            )
        }
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(runtimes, defaults: defaults, now: { clock.now })
        return (store, runtimes)
    }
}
