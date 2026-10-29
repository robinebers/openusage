import XCTest
import os
@testable import OpenUsage

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    func testRefreshAllPersistsAndPublishesAllProviderSnapshots() async {
        let fixtures = ["alpha", "beta", "gamma"].map { makeRuntime($0) }
        let ids = fixtures.map { $0.0.id }
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            fixtures.map { $0.1 },
            defaults: defaults
        )

        await store.refreshAll()

        XCTAssertEqual(Set(store.snapshots.keys), Set(ids))
        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").load()
        XCTAssertEqual(Set(persisted.keys), Set(ids))
    }

    func testForcedRefreshesWaitingOnOneReadTakeTurns() async throws {
        let account = Account(kind: .openrouter, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let firstRead = HeldResponse()
        let active = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
        let http = RoutingHTTPClient { _ in
            active.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            await firstRead.hold()
            try await Task.sleep(for: .milliseconds(20))
            active.withLock { $0.now -= 1 }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        let id = runtime.provider.id

        let first = Task { await store.refresh(providerID: id) }
        await firstRead.waitUntilHeld()
        let forced = (0..<2).map { _ in Task { await store.refresh(providerID: id, force: true) } }
        try await Task.sleep(for: .milliseconds(50))
        await firstRead.release()
        var untracked = false
        for _ in 0..<2000 where http.requests.count < 6 || active.withLock({ $0.now }) > 0 {
            if active.withLock({ $0.now }) > 0, !store.refreshingProviderIDs.contains(id) { untracked = true }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = await first.value
        for task in forced { _ = await task.value }

        XCTAssertEqual(http.requests.count, 6, "three reads of two requests each")
        XCTAssertEqual(active.withLock { $0.most }, 1, "two reads of one account ran at once")
        XCTAssertFalse(untracked, "a read ran while the account was not marked refreshing")
    }

    func testSingleProviderRefreshPersistsImmediately() async {
        let fixture = makeRuntime("single")
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [fixture.1],
            defaults: defaults
        )

        await store.refresh(providerID: fixture.0.id, force: true)

        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").load()
        XCTAssertNotNil(persisted[fixture.0.id])
    }

    func testAFinishedAccountShowsAndPersistsWithoutWaitingForThePass() async {
        let fast = makeRuntime("fast")
        let slowProvider = Provider(id: "slow", kind: .codex)
        let slowSnapshot = ProviderSnapshot(providerID: slowProvider.id, displayName: slowProvider.displayName, lines: [])
        let slow = SuspendedProviderRuntime(provider: slowProvider, snapshot: slowSnapshot)
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [fast.1, slow],
            defaults: defaults
        )
        let refreshTask = Task { await store.refreshAll() }

        for _ in 0..<1_000 where !slow.didStart { await Task.yield() }
        for _ in 0..<1_000 where store.snapshots[fast.0.id] == nil { await Task.yield() }
        XCTAssertTrue(slow.didStart)
        XCTAssertNotNil(store.snapshots[fast.0.id], "a finished account shows without waiting for the pass")
        XCTAssertNotNil(ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").load()[fast.0.id], "and its snapshot is on disk")

        slow.complete()
        await refreshTask.value
    }

    func testRefreshingSeveralAccountsStartsThemAllBeforeAnyFinishes() async {
        let providers = ["first", "second"].map { Provider(id: $0, kind: .codex) }
        let runtimes = providers.map {
            SuspendedProviderRuntime(provider: $0, snapshot: ProviderSnapshot(providerID: $0.id, displayName: $0.displayName, lines: []))
        }
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            runtimes,
            defaults: defaults
        )

        let refreshTask = Task { await store.refresh(providerIDs: providers.map(\.id), force: true) }
        for _ in 0..<1_000 where runtimes.contains(where: { !$0.didStart }) { await Task.yield() }

        XCTAssertTrue(runtimes.allSatisfy(\.didStart), "both accounts are in flight before either completes")
        XCTAssertEqual(store.refreshingProviderIDs, ["first", "second"])

        for runtime in runtimes { runtime.complete() }
        let outcomes = await refreshTask.value
        XCTAssertEqual(outcomes, [.refreshed, .refreshed])
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
    }

    func testResolvesProgressSnapshotIntoWidgetData() async {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "session",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(
                    label: "Session",
                    used: 42,
                    limit: 100,
                    format: .percent,
                    resetsAt: Date(timeIntervalSinceNow: 60 * 60),
                    periodDurationMs: 5 * 60 * 60 * 1000
                )]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)

        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.displayedValue, 58)
        XCTAssertEqual(data.valueText, "58%")
        guard case .bar(_, _, let value, let reset, _) = data.dashboardRow().mark else { return XCTFail("not a bar") }
        XCTAssertEqual(value, "58%")
        XCTAssertNotNil(reset, "a meter with a reset date shows its countdown")
    }

    func testBarFractionMatchesRoundedValue() {
        for (used, value, fraction) in [
            (0.3915, "0%", 0.0), (0.6, "1%", 0.01), (99.6, "100%", 1.0)
        ] {
            let data = WidgetData(
                title: "Total usage", kind: .percent,
                used: used, limit: 100
            )
            XCTAssertEqual(data.valueText, value)
            XCTAssertEqual(data.fraction, fraction, accuracy: 0.0001)
        }
    }

    func testCreditsRenderProviderReportedCountInvariantToMeterStyle() async {
        let provider = Provider(id: "codex", kind: .codex)
        let descriptor = WidgetDescriptor.values(
            key: "credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: CodexUsageMapper.creditValues(remaining: 1000))]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "1K credits")
        XCTAssertEqual(remaining.menuBarValue, "1K credits")
        XCTAssertEqual(remaining.dashboardRow().mark, .value("1K credits"))

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.dashboardRow(), remaining.dashboardRow())
    }

    func testRateLimitResetsTileShowsCountInTrayAndPopover() async {
        let provider = Provider(id: "codex", kind: .codex)
        let descriptor = WidgetDescriptor.values(
            key: "rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets"
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 1, kind: .count, label: "available")])]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "1 available")
        XCTAssertEqual(data.menuBarValue, "1 resets")
    }

    func testZeroRateLimitResetsStillFlagsResetPopoverForEmptyState() async {
        let provider = Provider(id: "codex", kind: .codex)
        let descriptor = WidgetDescriptor.values(
            key: "rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 0, kind: .count, label: "available")])]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.showsResetExpiries)
        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.expiriesAt.isEmpty)
        XCTAssertEqual(data.resetCreditCount, 0)
        XCTAssertEqual(data.unboundedDetail, "0 available")
    }

    func testBoundedDollarAndCountTrayValuesHonorMeterStyleWithoutPercentConversion() async {
        let provider = Provider(id: "example", kind: .cursor)
        let budget = WidgetDescriptor.boundedDollars(key: "budget", provider: provider, title: "Budget", limit: 100)
        let requests = WidgetDescriptor.boundedCount(
            key: "requests",
            provider: provider,
            title: "Requests",
            limit: 500,
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [budget, requests],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .progress(label: "Budget", used: 12.48, limit: 20, format: .dollars),
                    .progress(label: "Requests", used: 412, limit: 500, format: .count(suffix: "requests"))
                ]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$12")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "412")

        store.meterStyle = .remaining
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$8")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "88")
    }

    func testCursorCreditsRenderAsUnboundedBalance() async {
        let provider = Provider(id: "cursor", kind: .cursor)
        let descriptor = WidgetDescriptor.dollarBalance(
            key: "credits",
            provider: provider,
            title: "Credits",
            valueWord: "left"
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: [MetricValue(number: 7_909.64, kind: .dollars)])]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$7.9K left")
        XCTAssertEqual(remaining.menuBarValue, "$7.9K")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.menuBarValue, remaining.menuBarValue)
    }

    func testUncappedExtraUsageRendersCompactAndUnbounded() async {
        let provider = Provider(id: "claude", kind: .claude)
        let descriptor = WidgetDescriptor.boundedDollars(
            key: "extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"
        )
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Extra usage spent",
                                values: [MetricValue(number: 1234.56, kind: .dollars)])]
            )
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "$1.2K spent")
        XCTAssertEqual(data.menuBarValue, "$1.2K")
    }

    func testCreditValuesFloorAndClampBalance() {
        var data = WidgetData(title: "Extra Usage", kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 820.9)
        XCTAssertEqual(data.unboundedDetail, "820 credits")
        data.values = CodexUsageMapper.creditValues(remaining: -5)
        XCTAssertEqual(data.unboundedDetail, "0 credits")
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "session",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: isolatedDefaults(), storageKey: "snapshots")
        cache.save([provider.id: ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        )])
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: isolatedDefaults(), now: { now })

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "session",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = isolatedDefaults()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.save([provider.id: ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        )])
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: isolatedDefaults(), now: { now })

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }


    private func makeRuntime(_ id: String) -> (Provider, StubRuntime) {
        let provider = Provider(id: id, kind: .codex)
        return (
            provider,
            StubRuntime(
                provider: provider,
                descriptors: [],
                snapshot: ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: "Session", used: 1, limit: 100, format: .percent)]
                )
            )
        )
    }
}

@MainActor
private final class SuspendedProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let snapshot: ProviderSnapshot
    private(set) var didStart = false
    private var continuation: CheckedContinuation<Result<ProviderSnapshot, RefreshFailure>, Never>?

    init(provider: Provider, snapshot: ProviderSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        continuation?.resume(returning: .success(snapshot))
        continuation = nil
    }
}
