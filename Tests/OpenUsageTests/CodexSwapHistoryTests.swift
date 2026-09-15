import XCTest
@testable import OpenUsage

final class CodexSwapHistoryTests: XCTestCase {
    func testSharedAndCopiedRolloutsCountOnceForOneAccountAndAreExcludedForMultipleAccounts() async throws {
        let now = Date()
        let line = CodexLogFixture.tokenCount(timestamp: OpenUsageISO8601.string(from: now),
            last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2")
        let original = try CodexLogFixture.makeHome(files: ["sessions/original.jsonl": line])
        let copied = try CodexLogFixture.makeHome(files: ["sessions/copy.jsonl": line])
        let shared = original.appendingPathComponent("linked-home")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("sessions"),
                                                   withDestinationURL: original.appendingPathComponent("sessions"))
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: copied)
        }
        let environment = FakeEnvironment(["CODEX_HOME": original.path])
        let single = CodexLogUsageScanner(environment: environment,
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
            additionalHomes: [shared.path, copied.path])
        let counted = await single.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(counted?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        for _ in 0..<2 {
            let account = CodexLogUsageScanner(environment: environment,
                allowsUnattributedHistory: false, additionalHomes: [shared.path, copied.path])
            let excluded = await account.scan(now: now, pricing: TestPricing.bundled)
            XCTAssertNotNil(excluded, "An authoritative empty history clears previously cached unowned spending")
            XCTAssertTrue(excluded?.series.daily.isEmpty == true)
        }
    }

    func testSyncedCodexHistoryFollowsIdentityInsteadOfPeerCardIDsAndRejectsUnattributedHistory() throws {
        let now = Date()
        func history(_ tokens: Int) -> ProviderUsageHistory {
            ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: tokens, costUSD: 1)
            ]))
        }
        let identities = ["codex": "workspace-a|a@example.com", "codex@1234abcd": "workspace-b|b@example.com"]
        let document = UsageHistoryDocument(schema: UsageHistoryDocument.accountSchema,
            deviceID: "peer", deviceName: "Peer", updatedAt: now,
            providers: ["codex": history(20), "codex@87654321": history(10)],
            identities: ["codex": identities["codex@1234abcd"]!, "codex@87654321": identities["codex"]!])
        XCTAssertNoThrow(try document.validate())
        let decoded = try JSONDecoder().decode(UsageHistoryDocument.self, from: JSONEncoder().encode(document))
        let legacy = UsageHistoryDocument(deviceID: "legacy", deviceName: "Legacy", updatedAt: now,
                                          providers: ["codex": history(999)])
        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let merged = UsageHistoryAggregator.merged(localSnapshots: [:], peerDocuments: [decoded, decoded, legacy],
            descriptors: identities.mapValues { _ in descriptor }, providerIdentityKeys: identities, now: now)
        XCTAssertEqual(merged["codex"]?.series.daily.first?.totalTokens, 10)
        XCTAssertEqual(merged["codex@1234abcd"]?.series.daily.first?.totalTokens, 20)
    }

    @MainActor
    func testPartialIdentitiesNeitherImportNorExportHistory() throws {
        let provider = CodexProvider.makeProvider()
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: Date()), totalTokens: 123, costUSD: 1)
        ]))
        for identity in ["workspace-a|", "|personal@example.com"] {
            let suite = "CodexSwapPartialHistory.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "test-cache")
            cache.store(ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [], usageHistory: history),
                        producedByIdentityKey: identity)
            let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
                providers: [], cache: cache, defaults: defaults, providerIdentityKeys: ["codex": identity])
            XCTAssertNil(store.localHistoryDocument(deviceID: "local", deviceName: "Local").providers["codex"])
            let peer = UsageHistoryDocument(schema: UsageHistoryDocument.accountSchema,
                deviceID: "peer", deviceName: "Peer", updatedAt: Date(), providers: ["codex": history],
                identities: ["codex": identity])
            let merged = UsageHistoryAggregator.merged(localSnapshots: [:], peerDocuments: [peer],
                descriptors: ["codex": try XCTUnwrap(descriptor.historyResource)],
                providerIdentityKeys: ["codex": identity], now: Date())
            XCTAssertNil(merged["codex"])
        }
    }

    @MainActor
    func testExportedCodexCardsIncludeTheirIdentitiesAndValidate() throws {
        let suite = "CodexSwapExport.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = ["codex": "a|a@example.com", "codex@1234abcd": "b|b@example.com"]
        let providers = identities.keys.sorted().map { CodexProvider.makeProvider(id: $0) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "test-cache")
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        for provider in providers {
            cache.store(ProviderSnapshot(providerID: provider.id, displayName: "Codex", lines: [], usageHistory: history),
                        producedByIdentityKey: identities[provider.id])
        }
        let store = WidgetDataStore(registry: WidgetRegistry(providers: providers, descriptors: providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        }), providers: [], cache: cache, defaults: defaults, providerIdentityKeys: identities)
        let document = store.localHistoryDocument(deviceID: "local", deviceName: "Local")
        XCTAssertEqual(document.schema, UsageHistoryDocument.accountSchema)
        XCTAssertEqual(document.identities, identities)
        XCTAssertNoThrow(try document.validate())
    }
}
