import XCTest
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
        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
            .loadSnapshots(providerIDs: ids)
        XCTAssertEqual(Set(persisted.keys), Set(ids))
    }

    func testSingleProviderRefreshPersistsImmediately() async {
        let fixture = makeRuntime("single")
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [fixture.1],
            defaults: defaults
        )

        await store.refresh(providerID: fixture.0.id, force: true)

        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
            .loadSnapshots(providerIDs: [fixture.0.id])
        XCTAssertNotNil(persisted[fixture.0.id])
    }

    func testAFinishedAccountShowsAndPersistsWithoutWaitingForThePass() async {
        let fast = makeRuntime("fast")
        let slowProvider = Provider(id: "slow", displayName: "Slow", icon: "codex")
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
        XCTAssertNotNil(ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
            .loadSnapshots(providerIDs: [fast.0.id])[fast.0.id], "and its snapshot is on disk")

        slow.complete()
        await refreshTask.value
    }

    /// A provider's Refresh covers its accounts side by side, as Refresh All does: both start before
    /// either finishes, so one slow account never holds the other behind its deadline.
    func testRefreshingSeveralAccountsStartsThemAllBeforeAnyFinishes() async {
        let providers = ["first", "second"].map { Provider(id: $0, displayName: $0, icon: "codex") }
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
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
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
        // Hermetic: pin the meter style and the snapshot cache via an isolated suite, so neither a persisted
        // `.used` nor a snapshot another test left in `.standard` can stand in for this refresh.
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
        // Codex flex credits are provider-reported counts, with no locally estimated dollar value.
        let provider = Provider(id: "codex", displayName: "Codex", icon: "codex")
        let descriptor = WidgetDescriptor.values(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
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
        // The menu-bar tile and the popover row resolve from one raw number, so a
        // pinned tile can't read "0" while the popover reads "1". The popover keeps Codex's "available"
        // wording, while the tighter tray reads "resets".
        let provider = Provider(id: "codex", displayName: "Codex", icon: "codex")
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
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
        // The descriptor opt-in must survive resolve even at "0 available" (no expiries): that's exactly
        // when the value column needs to stay a hover target so the popover can show the empty state.
        let provider = Provider(id: "codex", displayName: "Codex", icon: "codex")
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
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
        let provider = Provider(id: "example", displayName: "Example", icon: "cursor")
        let budget = WidgetDescriptor.boundedDollars(id: "example.budget", provider: provider, title: "Budget", limit: 100)
        let requests = WidgetDescriptor.boundedCount(
            id: "example.requests",
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
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: "cursor")
        let descriptor = WidgetDescriptor.dollarBalance(
            id: "cursor.credits",
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
        // Claude's `claude.extra` is a `boundedDollars` descriptor (a meter when the
        // provider reports a monthly cap), but an uncapped spend arrives as a `.values` line. It must
        // resolve to an unbounded tile — the sample's placeholder limit dropped — and read in the same
        // compact shorthand as the spend tiles ("$1.2K spent"), not full currency, in both row and tray.
        let provider = Provider(id: "claude", displayName: "Claude", icon: "claude")
        let descriptor = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
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
        XCTAssertFalse(data.isBounded)                          // sample's limit: 100 dropped for a .values row
        XCTAssertEqual(data.unboundedDetail, "$1.2K spent")     // popover row — compact, not "$1,234.56"
        XCTAssertEqual(data.menuBarValue, "$1.2K")              // tray — same shorthand
    }

    func testCreditValuesFloorAndClampBalance() {
        var data = WidgetData(title: "Extra Usage", kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 820.9)
        XCTAssertEqual(data.unboundedDetail, "820 credits")
        // An exhausted/negative balance clamps to a real, measured zero, not "No data".
        data.values = CodexUsageMapper.creditValues(remaining: -5)
        XCTAssertEqual(data.unboundedDetail, "0 credits")
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(
            userDefaults: isolatedDefaults(),
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        ))
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
        let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: isolatedDefaults())

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", displayName: "Test", icon: "codex")
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = isolatedDefaults()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        ))
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
        let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: isolatedDefaults())

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }


    private func makeRuntime(_ id: String) -> (Provider, StubRuntime) {
        let provider = Provider(id: id, displayName: id.capitalized, icon: "codex")
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
    private var continuation: CheckedContinuation<ProviderSnapshot, Never>?

    init(provider: Provider, snapshot: ProviderSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
