import XCTest
@testable import OpenUsage

@MainActor
final class SharedLocalHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: UsageHistoryWindow.dayKeys(through: now).sorted().last!, totalTokens: tokens, costUSD: cost)
        ]))
    }

    func testSharedTotalsRemainLocalAndDoNotReplaceAccountLimitsOrExports() async throws {
        let suite = "SharedLocalHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let shared = history(tokens: 1000, cost: 10)
        let owned = history(tokens: 100, cost: 1)
        var scans = 0
        let source = SharedLocalHistorySource(family: "claude") { _ in
            scans += 1
            await Task.yield()
            return shared
        }
        let cards = ["claude@aaaaaaaa", "claude@bbbbbbbb"].map { id in
            runtime(id: id, history: owned, source: source)
        }
        let registry = WidgetRegistry.from(cards)
        let store = WidgetDataStore(
            registry: registry, providers: cards, cache: cache, defaults: defaults,
            now: { self.now }, providerIdentityKeys: [cards[0].provider.id: "a|org-a", cards[1].provider.id: "b|org-b"]
        )
        await store.refreshAll(force: true)
        await store.waitForSharedHistory()

        XCTAssertEqual(scans, 1, "one family scan serves both account cards")
        for card in cards {
            let id = card.provider.id
            let today = try XCTUnwrap(card.widgetDescriptors.first { $0.metricLabel == "Today" })
            XCTAssertEqual(store.data(for: today).title, "Today · Shared")
            XCTAssertEqual(store.snapshots[id]?.sharedHistoryFamily, "claude")
            XCTAssertEqual(store.snapshots[id]?.line(label: "Session"), card.snapshot.line(label: "Session"))
            XCTAssertEqual(store.exportSnapshots[id]?.usageHistory, owned)
            XCTAssertEqual(cache.loadSnapshots(providerIDs: [id])[id]?.usageHistory, owned)
            XCTAssertNil(cache.loadSnapshots(providerIDs: [id])[id]?.sharedHistoryFamily)
        }
        let providers = cards.map(\.provider)
        XCTAssertEqual(TotalSpendAggregator.total(for: .today, providers: providers, snapshots: store.exportSnapshots).totalUSD, 2)
        for visible in [providers, Array(providers.reversed()), [providers[1]]] {
            let total = TotalSpendAggregator.total(for: .today, providers: visible, snapshots: store.snapshots)
            XCTAssertEqual(total.totalUSD, 10)
            XCTAssertEqual(total.totalTokens, 1000)
            XCTAssertEqual(total.slices.count, 1)
        }
        let document = store.localHistoryDocument(deviceID: "local", deviceName: "Mac", updatedAt: now)
        XCTAssertEqual(document.providers.values.map { $0.series.daily[0].totalTokens }.sorted(), [100, 100])

        let peer = UsageHistoryDocument(
            schema: UsageHistoryDocument.accountSchema, deviceID: "peer", deviceName: "Other Mac", updatedAt: now,
            providers: [cards[0].provider.id: owned], identities: [cards[0].provider.id: "a|org-a"]
        )
        store.setPeerHistoryDocuments([peer], ownDeviceID: "local")
        XCTAssertEqual(TotalSpendAggregator.total(for: .today, providers: providers, snapshots: store.exportSnapshots).totalUSD, 3)
        XCTAssertEqual(store.exportSnapshots[cards[0].provider.id]?.sharedHistoryFamily, nil)
        XCTAssertEqual(TotalSpendAggregator.total(for: .today, providers: providers, snapshots: store.snapshots).totalUSD, 10)

        // Even callers accidentally passing the display projection cannot export shared spend.
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: providers.map(\.id), knownIDs: Set(providers.map(\.id)), snapshots: store.snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider, generatedAt: now
        )
        for path in ["/v1/usage", "/v1/usage/claude", "/v1/usage/claude@aaaaaaaa", "/v1/limits/claude@aaaaaaaa"] {
            let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
            let body = String(decoding: try XCTUnwrap(response.body), as: UTF8.self)
            XCTAssertFalse(body.contains("Today"))
            XCTAssertFalse(body.contains("Usage Trend"))
            if path.hasPrefix("/v1/limits") {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body!) as? [String: Any])
                let exported = try XCTUnwrap(json["providers"] as? [String: [String: Any]])
                let resources = try XCTUnwrap(exported[cards[0].provider.id]?["resources"] as? [String: Any])
                XCTAssertEqual(Set(resources.keys), ["session"])
            }
        }
    }

    func testSlowSharedScanDoesNotHoldLiveLimitsAndReusesInFlightWork() async throws {
        let suite = "SharedLocalHistoryTests.slow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<ProviderUsageHistory?, Never>?
        var scans = 0
        let source = SharedLocalHistorySource(family: "codex") { _ in
            scans += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let card = runtime(id: "codex@aaaaaaaa", history: nil, source: source)
        let store = WidgetDataStore(registry: .from([card]), providers: [card],
                                    cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, now: { self.now })
        await store.refresh(providerID: card.provider.id, force: true)
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(store.snapshots[card.provider.id]?.line(label: "Session"), card.snapshot.line(label: "Session"))
        await store.refresh(providerID: card.provider.id, force: true)
        XCTAssertEqual(scans, 1)
        continuation?.resume(returning: history(tokens: 100, cost: 1))
        await store.waitForSharedHistory()
        XCTAssertNotNil(store.snapshots[card.provider.id]?.line(label: "Today"))
    }

    func testPreviouslyAttributedCacheAndUnownedPeerHistoryAreNotExported() throws {
        let suite = "SharedLocalHistoryTests.cache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let source = SharedLocalHistorySource(family: "claude") { _ in nil }
        let fixture = runtime(id: "claude@aaaaaaaa", history: history(tokens: 900, cost: 9), source: source)
        cache.store(fixture.snapshot, producedByIdentityKey: "a|org-a")
        let runtime = ClaudeProvider(provider: fixture.provider, allowsUnattributedPiUsage: false, sharedHistorySource: source)
        let store = WidgetDataStore(registry: .from([runtime]), providers: [runtime], cache: cache, defaults: defaults,
                                    now: { self.now }, providerIdentityKeys: [runtime.provider.id: "a|org-a"])
        XCTAssertNil(store.exportSnapshots[runtime.provider.id]?.usageHistory)
        XCTAssertNil(store.exportSnapshots[runtime.provider.id]?.line(label: "Today"))
        XCTAssertEqual(store.exportSnapshots[runtime.provider.id]?.line(label: "Session"), fixture.snapshot.line(label: "Session"))
        XCTAssertEqual(store.exportSnapshots[runtime.provider.id]?.refreshedAt, now)
        store.setPeerHistoryDocuments([
            UsageHistoryDocument(deviceID: "peer", deviceName: "Other Mac", updatedAt: now,
                                 providers: ["claude": history(tokens: 1000, cost: 10)])
        ], ownDeviceID: "local")
        XCTAssertNil(store.exportSnapshots[runtime.provider.id]?.line(label: "Today"))
        XCTAssertTrue(store.localHistoryDocument(deviceID: "local", deviceName: "Mac", updatedAt: now).providers.isEmpty)
    }

    func testLocalHistoryLoadsDespiteAccountFailureAndEmptyScanClearsIt() async throws {
        let suite = "SharedLocalHistoryTests.failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scanned = history(tokens: 900, cost: 9)
        let source = SharedLocalHistorySource(family: "codex") { _ in scanned }
        let card = runtime(id: "codex@aaaaaaaa", history: nil, source: source, fails: true)
        let registry = WidgetRegistry.from([card])
        let store = WidgetDataStore(registry: registry, providers: [card],
                                    cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, now: { self.now })
        await store.refreshAll(force: true)
        await store.waitForSharedHistory()
        XCTAssertNotNil(store.providerErrors[card.provider.id])
        XCTAssertNil(store.exportSnapshots[card.provider.id])
        XCTAssertNotNil(store.snapshots[card.provider.id]?.line(label: "Today"))
        XCTAssertTrue(store.localHistoryDocument(deviceID: "local", deviceName: "Mac", updatedAt: now).providers.isEmpty)

        scanned = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        await store.refresh(providerID: card.provider.id, force: true)
        await store.waitForSharedHistory()
        XCTAssertEqual(TotalSpendAggregator.total(for: .today, providers: [card.provider], snapshots: store.snapshots).totalUSD, 0)
        XCTAssertNotNil(store.providerErrors[card.provider.id])
    }

    private func runtime(
        id: String, history: ProviderUsageHistory?, source: SharedLocalHistorySource, fails: Bool = false
    ) -> TestProviderRuntime {
        let provider = Provider(id: id, displayName: id, icon: .providerMark(source.family))
        let descriptors = [
            WidgetDescriptor.percent(id: "\(id).session", provider: provider, title: "Session").exportingLimit("session", unit: "percent"),
            .usageTrend(provider: provider).exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        ] + WidgetDescriptor.spendTiles(provider: provider)
        var snapshot = ProviderSnapshot(providerID: id, displayName: id,
                                        lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
                                        refreshedAt: now, usageHistory: history)
        if let history {
            snapshot = UsageHistorySnapshotRenderer.render(local: snapshot, history: history,
                descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs"), now: now, combined: false)
        }
        let result = TestProviderRuntime(provider: provider, descriptors: descriptors,
                                        snapshot: fails ? .error(provider: provider, message: "Sign in again") : snapshot)
        result.sharedHistorySource = source
        return result
    }
}
