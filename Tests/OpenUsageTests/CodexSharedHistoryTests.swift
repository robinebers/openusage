import XCTest
@testable import OpenUsage

@MainActor
final class CodexSharedHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 4_102_444_800)

    private func defaults() throws -> UserDefaults {
        let name = "CodexSharedHistory.\(UUID().uuidString)"
        let result = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func runtime(_ id: String = "codex", shared: Bool = true) -> CodexProvider {
        CodexProvider(provider: CodexProvider.makeProvider(id: id), sharesLocalHistory: shared)
    }

    private func snapshot(_ id: String, tokens: Int = 150, shared: Bool = true,
                          age: TimeInterval = 0) -> ProviderSnapshot {
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            .init(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: tokens, costUSD: 2)
        ]))
        return UsageHistorySnapshotRenderer.render(
            local: .init(providerID: id, displayName: id,
                         lines: [.progress(label: "Weekly", used: 17, limit: 100, format: .percent)],
                         refreshedAt: now.addingTimeInterval(-age), usageHistory: history,
                         sharedHistoryGroup: shared ? "codex" : nil),
            history: history,
            descriptor: .init(scope: .machineLocal, estimatedCost: true, sourceNote: "logs"),
            now: now, combined: false)
    }

    func testSharedProviderReadsDeduplicatedHistoryAndKeepsAccountLimits() async throws {
        let date = now
        let line = CodexLogFixture.tokenCount(timestamp: OpenUsageISO8601.string(from: date),
            last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2")
        let home = try CodexLogFixture.makeHome(files: ["sessions/original.jsonl": line])
        let copy = try CodexLogFixture.makeHome(files: ["sessions/copied.jsonl": line])
        for file in [home.appendingPathComponent("sessions/original.jsonl"),
                     copy.appendingPathComponent("sessions/copied.jsonl")] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: copy)
        }
        for (id, used) in [("codex", 17.0), ("codex@1234abcd", 42.0)] {
            let provider = CodexProvider(provider: CodexProvider.makeProvider(id: id),
                logUsageScanner: .init(environment: FakeEnvironment(["CODEX_HOME": home.path]),
                    incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                    additionalHomes: [copy.path]),
                sharesLocalHistory: true, now: { date }, pricing: { TestPricing.bundled })
            let weekly = MetricLine.progress(label: "Weekly", used: used, limit: 100, format: .percent)
            let result = await provider.snapshot(mapped: .init(plan: "Pro", lines: [weekly]))
            XCTAssertEqual(result.sharedHistoryGroup, "codex")
            XCTAssertEqual(result.usageHistory?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
            XCTAssertEqual(result.line(label: "Weekly"), weekly)
            XCTAssertNotNil(result.line(label: "Today"))
        }
    }

    func testOnlyHistoryRowsAreMarkedSharedIncludingWhenNoData() throws {
        for shared in [false, true] {
            let provider = runtime(shared: shared)
            let registry = WidgetRegistry.from([provider])
            let defaults = try defaults()
            let store = WidgetDataStore(registry: registry, providers: [],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache"), defaults: defaults)
            for descriptor in provider.widgetDescriptors {
                let isHistory = descriptor.isSpendTile || descriptor.sample.isChart
                XCTAssertEqual(store.data(for: descriptor).isSharedHistory, shared && isHistory,
                               descriptor.id)
            }
        }
    }

    func testTotalsCountFreshestEnabledSharedCopyOnceAndDoNotAttributeItToAnAccount() {
        let a = runtime().provider
        let b = runtime("codex@1234abcd").provider
        let cursor = Provider(id: "cursor", displayName: "Cursor", icon: a.icon)
        let snapshots = [a.id: snapshot(a.id, tokens: 100, age: 60),
                         b.id: snapshot(b.id, tokens: 150),
                         cursor.id: snapshot(cursor.id, tokens: 25, shared: false)]
        for order in [[a, b, cursor], [b, a, cursor], [b, cursor]] {
            let total = TotalSpendAggregator.total(for: .today, providers: order, snapshots: snapshots)
            XCTAssertEqual(total.totalTokens, 175)
            XCTAssertEqual(total.totalUSD, 4)
            XCTAssertEqual(total.slices.count, 2)
            XCTAssertEqual(total.slices.first { $0.id == "codex-shared" }?.provider.displayName,
                           "Codex (All Accounts)")
        }
        let onlyA = TotalSpendAggregator.total(for: .today, providers: [a], snapshots: snapshots)
        XCTAssertEqual(onlyA.totalTokens, 100)
    }

    func testSharedHistorySurvivesCacheButNeverImportsOrExportsAsAccountHistory() throws {
        let defaults = try defaults()
        let runtimes = [runtime(), runtime("codex@1234abcd")]
        let registry = WidgetRegistry.from(runtimes)
        let identities = ["codex": "workspace-a|a@example.com", "codex@1234abcd": "workspace-b|b@example.com"]
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache")
        for provider in runtimes {
            cache.store(snapshot(provider.provider.id), producedByIdentityKey: identities[provider.provider.id])
        }
        let store = WidgetDataStore(registry: registry, providers: runtimes, cache: cache, defaults: defaults,
                                    now: { self.now },
                                    providerIdentityKeys: identities)
        for provider in runtimes {
            XCTAssertEqual(store.snapshots[provider.provider.id]?.usageHistory?.series.daily.first?.totalTokens, 150)
            let today = try XCTUnwrap(provider.widgetDescriptors.first { $0.metricLabel == "Today" })
            XCTAssertTrue(store.data(for: today).isSharedHistory)
            XCTAssertTrue(store.data(for: today).hasData)
        }
        let document = store.localHistoryDocument(deviceID: "local", deviceName: "Local")
        XCTAssertTrue(document.providers.isEmpty)
        XCTAssertNoThrow(try document.validate())
        let peer = UsageHistoryDocument(schema: UsageHistoryDocument.accountSchema,
            deviceID: "peer", deviceName: "Peer", updatedAt: now,
            providers: ["codex": try XCTUnwrap(snapshot("codex", tokens: 999).usageHistory)],
            identities: ["codex": identities["codex"]!])
        let merged = UsageHistoryAggregator.merged(localSnapshots: store.localSnapshots, peerDocuments: [peer],
            descriptors: registry.historyDescriptorsByProvider, providerIdentityKeys: identities, now: now)
        XCTAssertTrue(merged.isEmpty, "Shared local history must not be mixed with one account's peer history")
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self,
            from: JSONEncoder().encode(snapshot("codex")))
        XCTAssertEqual(decoded.sharedHistoryGroup, "codex")
    }

    func testChangingHistoryScopeClearsCacheWithoutChangingLimitsOrFreshness() throws {
        for shared in [false, true] {
            let defaults = try defaults()
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache")
            let original = snapshot("codex", shared: !shared)
            cache.store(original, producedByIdentityKey: "a|a@example.com")
            cache.removeExcludedHistory(for: [runtime(shared: shared)])
            let result = try XCTUnwrap(cache.loadSnapshots(providerIDs: ["codex"])["codex"])
            XCTAssertNil(result.usageHistory)
            XCTAssertNil(result.sharedHistoryGroup)
            XCTAssertNil(result.line(label: "Today"))
            XCTAssertEqual(result.line(label: "Weekly"), original.line(label: "Weekly"))
            XCTAssertEqual(result.refreshedAt, original.refreshedAt)
            XCTAssertEqual(cache.producedByIdentityKey(providerID: "codex"), "a|a@example.com")
        }
    }

    func testSharedRowsReachAnExpiredOrNewCardWithoutReplacingItsLimitsOrFreshness() throws {
        let a = runtime()
        let b = runtime("codex@1234abcd")
        let c = runtime("codex@87654321")
        let registry = WidgetRegistry.from([a, b, c])
        let stale = ProviderSnapshot(providerID: b.provider.id, displayName: "Work", plan: "Team",
            lines: [.progress(label: "Weekly", used: 42, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-900))
        let result = SharedHistorySnapshotRenderer.render(
            snapshots: [a.provider.id: snapshot(a.provider.id), b.provider.id: stale],
            providers: registry.providers, descriptors: registry.historyDescriptorsByProvider, now: now)
        for id in [a.provider.id, b.provider.id, c.provider.id] {
            XCTAssertEqual(result[id]?.usageHistory?.series.daily.first?.totalTokens, 150)
            XCTAssertNotNil(result[id]?.line(label: "Today"))
            XCTAssertEqual(result[id]?.sharedHistoryGroup, "codex")
        }
        XCTAssertEqual(result[b.provider.id]?.line(label: "Weekly"), stale.line(label: "Weekly"))
        XCTAssertEqual(result[b.provider.id]?.plan, "Team")
        XCTAssertEqual(result[b.provider.id]?.refreshedAt, stale.refreshedAt)
        XCTAssertNil(result[c.provider.id]?.line(label: "Weekly"))
        XCTAssertEqual(result[c.provider.id]?.refreshedAt, .distantPast)
        let total = TotalSpendAggregator.total(for: .today, providers: [b.provider, c.provider], snapshots: result)
        XCTAssertEqual(total.totalTokens, 150)
    }

    func testLocalAPIExplicitlyIdentifiesSharedHistory() throws {
        for shared in [false, true] {
            let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: .init(
                enabledOrderedIDs: ["codex"], knownIDs: ["codex"],
                snapshots: ["codex": snapshot("codex", shared: shared)]))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [[String: Any]])
            XCTAssertEqual(payload.first?["sharedHistoryGroup"] as? String, shared ? "codex" : nil)
        }
    }
}
