import XCTest
@testable import OpenUsage

/// The wait after a failed refresh, driven through `WidgetDataStore` on a fake clock: a 429 honours its
/// Retry-After and holds off manual refreshes too, a 429 without one and an account that keeps failing
/// both double from 5 minutes up to an hour, a success resets the wait, and no answer at all never grows it.
@MainActor
final class RefreshBackoffTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testRateLimitHonoursRetryAfterAndKeepsTheLastGoodNumbers() async {
        let clock = TestClock(start)
        let runtime = makeRuntime([ok(at: start), rateLimited(retryAfter: 1800), ok(at: start)])
        let store = makeStore(runtime, clock: clock)

        await store.refreshAll()
        clock.set(start.addingTimeInterval(600))
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 2)
        let retryAt = start.addingTimeInterval(600 + 1800)

        XCTAssertNil(store.errorMessage(for: "test"), "a provider-set wait is the clock glyph, not the warning")
        XCTAssertEqual(
            store.stalenessHint(for: "test"),
            "Test asked OpenUsage to wait. Retrying at \(Formatters.compactClock(retryAt, now: clock.now))."
        )
        XCTAssertEqual(store.data(for: descriptor).used, 12, "the last good numbers stay on screen")

        clock.set(retryAt.addingTimeInterval(-1))
        await store.refreshAll()
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.refreshCount, 2, "neither the loop nor a manual refresh asks before Retry-After")

        clock.set(retryAt)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 3)
        XCTAssertNil(store.backoffs["test"])
    }

    func testRateLimitWithoutRetryAfterDoublesFromFiveMinutesToAnHour() async {
        let clock = TestClock(start)
        let runtime = makeRuntime([rateLimited(retryAfter: nil)])
        let store = makeStore(runtime, clock: clock)

        await store.refreshAll()
        for minutes in [5, 10, 20, 40, 60, 60] {
            await assertNextAttempt(after: TimeInterval(minutes * 60), store: store, runtime: runtime, clock: clock, force: true)
        }
    }

    func testAccountThatKeepsFailingBacksOffExponentiallyButManualRefreshRetries() async {
        let clock = TestClock(start)
        let runtime = makeRuntime([.error(provider: provider, error: ProviderError.signInExpired(.openrouter))])
        let store = makeStore(runtime, clock: clock)

        await store.refreshAll()
        for minutes in [5, 10, 20, 40, 60, 60] {
            await assertNextAttempt(after: TimeInterval(minutes * 60), store: store, runtime: runtime, clock: clock, force: false)
        }
        XCTAssertNotNil(store.errorMessage(for: "test"), "a refused sign-in still raises the warning")

        clock.set(clock.now.addingTimeInterval(1))
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.refreshCount, 8, "a manual refresh skips the client's own backoff")
    }

    func testSuccessResetsTheBackoff() async {
        let clock = TestClock(start)
        let failure = ProviderSnapshot.error(provider: provider, error: ProviderError.requestFailed(500))
        let runtime = makeRuntime([failure, failure, failure, ok(at: start), failure])
        let store = makeStore(runtime, clock: clock)

        await store.refreshAll()
        await assertNextAttempt(after: 300, store: store, runtime: runtime, clock: clock, force: false)
        await assertNextAttempt(after: 600, store: store, runtime: runtime, clock: clock, force: false)
        await assertNextAttempt(after: 1200, store: store, runtime: runtime, clock: clock, force: false)
        XCTAssertNil(store.errorMessage(for: "test"))
        XCTAssertNil(store.backoffs["test"])

        clock.set(clock.now.addingTimeInterval(RefreshSetting.interval))
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 5)
        await assertNextAttempt(after: 300, store: store, runtime: runtime, clock: clock, force: false)
    }

    func testNoAnswerRetriesEveryPassWithoutGrowingTheWait() async {
        let clock = TestClock(start)
        let runtime = makeRuntime([.error(provider: provider, error: URLError(.notConnectedToInternet))])
        let store = makeStore(runtime, clock: clock)

        await store.refreshAll()
        for _ in 0..<4 {
            await assertNextAttempt(after: 300, store: store, runtime: runtime, clock: clock, force: false)
        }
    }

    func testRetryAfterReadsSecondsAndHTTPDates() {
        func response(_ value: String?) -> HTTPResponse {
            HTTPResponse(statusCode: 429, headers: value.map { ["retry-after": $0] } ?? [:], body: Data())
        }
        XCTAssertEqual(response("120").retryAfter(now: start), 120)
        let date = Date(timeIntervalSince1970: 1_800_000_000 + 3000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(response(formatter.string(from: date)).retryAfter(now: start), 3000)
        XCTAssertNil(response(nil).retryAfter(now: start))
        XCTAssertNil(response("0").retryAfter(now: start), "a zero wait names no wait, so the doubling applies")
        XCTAssertNil(response("soon").retryAfter(now: start))
    }

    func testA429ReadsAsARateLimitEverywhereRequireSuccessRuns() {
        let response = HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data())
        XCTAssertThrowsError(try ProviderAuthRetry.requireSuccess(response, kind: .claude)) { error in
            XCTAssertEqual(error as? ProviderError, .rateLimited(retryAfter: 60))
        }
        let snapshot = ProviderSnapshot.error(provider: provider, error: ProviderError.rateLimited(retryAfter: 60))
        XCTAssertEqual(snapshot.failure?.kind, .rateLimited(retryAfter: 60))
    }

    // MARK: - Helpers

    private let provider = Provider(id: "test", displayName: "Test", icon: "claude")

    private var descriptor: WidgetDescriptor {
        WidgetDescriptor(
            id: "test.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
    }

    /// Advances to one second before the expected next attempt (nothing is asked), then to it (one request).
    private func assertNextAttempt(
        after wait: TimeInterval,
        store: WidgetDataStore,
        runtime: StubRuntime,
        clock: TestClock,
        force: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let count = runtime.refreshCount
        let from = clock.now
        clock.set(from.addingTimeInterval(wait - 1))
        await store.refreshAll(force: force)
        XCTAssertEqual(runtime.refreshCount, count, "asked before the \(Int(wait))s wait ended", file: file, line: line)
        clock.set(from.addingTimeInterval(wait))
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, count + 1, "not asked once the \(Int(wait))s wait ended", file: file, line: line)
    }

    private func ok(at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
            refreshedAt: date
        )
    }

    private func rateLimited(retryAfter: TimeInterval?) -> ProviderSnapshot {
        .error(provider: provider, error: ProviderError.rateLimited(retryAfter: retryAfter))
    }

    private func makeRuntime(_ snapshots: [ProviderSnapshot]) -> StubRuntime {
        StubRuntime(provider: provider, descriptors: [descriptor], snapshots: snapshots)
    }

    private func makeStore(_ runtime: StubRuntime, clock: TestClock) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        return WidgetDataStore.forTesting(
            [runtime],
            defaults: defaults,
            now: { clock.now }
        )
    }
}
