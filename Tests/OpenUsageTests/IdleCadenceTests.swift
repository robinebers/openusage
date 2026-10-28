import XCTest
@testable import OpenUsage

/// Passes run every 5 minutes while the user is active or the popover is open, every 15 once the Mac
/// has had no input for 10 minutes; opening the popover refreshes only accounts whose numbers are more
/// than 5 minutes old, and never one waiting out a backoff.
@MainActor
final class IdleCadenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testCadenceFollowsInputAndThePopover() {
        XCTAssertEqual(RefreshSetting.passInterval(secondsSinceInput: 0, popoverOpen: false), 5 * 60)
        XCTAssertEqual(RefreshSetting.passInterval(secondsSinceInput: 10 * 60 - 1, popoverOpen: false), 5 * 60)
        XCTAssertEqual(RefreshSetting.passInterval(secondsSinceInput: 10 * 60, popoverOpen: false), 15 * 60)
        XCTAssertEqual(RefreshSetting.passInterval(secondsSinceInput: 3 * 3600, popoverOpen: false), 15 * 60)
        XCTAssertEqual(RefreshSetting.passInterval(secondsSinceInput: 3 * 3600, popoverOpen: true), 5 * 60)
    }

    func testOpeningThePopoverRefreshesOnlyAccountsOlderThanFiveMinutes() async {
        let clock = TestClock(start)
        let stale = clockRuntime("stale", clock: clock)
        let recent = clockRuntime("recent", clock: clock)
        let store = makeStore([stale, recent], clock: clock)
        await store.refreshAll()

        clock.set(start.addingTimeInterval(4 * 60))
        await store.refreshManually(providerIDs: ["recent"])
        clock.set(start.addingTimeInterval(9 * 60))
        await store.refreshStale(olderThan: RefreshSetting.popoverStaleAge)

        XCTAssertEqual(stale.refreshCount, 2, "9 minutes old: refreshed on open")
        XCTAssertEqual(recent.refreshCount, 2, "5 minutes old: left alone")
    }

    func testOpeningThePopoverRespectsABackoff() async {
        let clock = TestClock(start)
        let provider = Provider(id: "limited", displayName: "Limited", icon: "claude")
        let limited = clockRuntime("limited", clock: clock, failure: .error(provider: provider, error: ProviderError.rateLimited(retryAfter: 3600)))
        let store = makeStore([limited], clock: clock)
        await store.refreshAll()

        clock.set(start.addingTimeInterval(20 * 60))
        await store.refreshStale(olderThan: RefreshSetting.popoverStaleAge)
        XCTAssertEqual(limited.refreshCount, 1)
    }

    func testASavedSnapshotExpiresWhenTheNextPassIsDue() async throws {
        XCTAssertEqual(RefreshSetting.expectedInterval(secondsSinceInput: 0), 5 * 60)
        XCTAssertEqual(RefreshSetting.expectedInterval(secondsSinceInput: 5 * 60 - 1), 5 * 60)
        XCTAssertEqual(RefreshSetting.expectedInterval(secondsSinceInput: 5 * 60), 15 * 60, "idle by the next pass")

        let clock = TestClock(start)
        let runtime = clockRuntime("idle", clock: clock)
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [runtime],
            defaults: defaults,
            now: { clock.now },
            expectedRefreshInterval: { RefreshSetting.idleInterval }
        )
        await store.refreshAll()

        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { clock.now })
        let saved = try XCTUnwrap(cache.loadSnapshots(providerIDs: ["idle"])["idle"])
        XCTAssertEqual(saved.nextRefreshAt, start.addingTimeInterval(15 * 60))
    }

    // MARK: - Helpers

    private func makeStore(_ runtimes: [StubRuntime], clock: TestClock) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        return WidgetDataStore.forTesting(runtimes, defaults: defaults, now: { clock.now })
    }

    /// Answers each refresh with numbers fetched at the test clock's now, or with `failure`.
    private func clockRuntime(_ id: String, clock: TestClock, failure: ProviderSnapshot? = nil) -> StubRuntime {
        let provider = Provider(id: id, displayName: id, icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "\(id).weekly", providerID: id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
        )
        return StubRuntime(provider: provider, descriptors: [descriptor]) { _ in
            failure ?? ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
                refreshedAt: clock.now
            )
        }
    }
}
