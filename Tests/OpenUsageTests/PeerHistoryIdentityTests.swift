import XCTest
@testable import OpenUsage

/// Identity-keyed iCloud matching: the same account merges into the same card across Macs regardless
/// of which machine calls it the default and which calls it an instance, and accounts with no local
/// card surface as remote-only Total Spend entries.
@MainActor
final class PeerHistoryIdentityTests: XCTestCase {
    private let teamKey = "uuid-me|org-team"
    private let maxKey = "uuid-me|org-max"

    func testDocumentV2AllowsInstanceCardsAndV1StaysStrict() throws {
        var v2 = makeDocument(providers: [
            "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
            "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2)
        ], identities: ["claude": maxKey, "claude@ab12cd34": teamKey])
        XCTAssertNoThrow(try v2.validate())

        v2.schema = UsageHistoryDocument.legacySchemaV1
        XCTAssertThrowsError(try v2.validate()) // instance ids are a v2 concept

        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "n", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        XCTAssertNoThrow(try v1.validate())
    }

    func testRemapMatchesAccountsAcrossDefaultAndInstanceRoles() {
        // The mini↔MacBook case: mini's DEFAULT card is the Team account (claude), its instance is
        // Max. This Mac is the mirror image (default = Max, instance = Team). Every peer history must
        // land on the LOCAL card with the same account.
        let miniDoc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude": history(day: "2026-07-16", tokens: 100, cost: 502.34),
                "claude@b2d3867d": history(day: "2026-07-16", tokens: 90, cost: 494.27)
            ],
            identities: ["claude": teamKey, "claude@b2d3867d": maxKey]
        )
        let localMap = ["claude": maxKey, "claude@f15456b0": teamKey]

        let remapped = PeerHistoryRemapper.remap(documents: [miniDoc], localIdentityByCardID: localMap)

        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        let byCard = Dictionary(grouping: remapped.histories, by: { $0.cardID })
        XCTAssertEqual(byCard["claude"]?.first?.history.series.daily.first?.costUSD, 494.27, "mini's Max spend belongs to this Mac's default (Max) card")
        XCTAssertEqual(byCard["claude@f15456b0"]?.first?.history.series.daily.first?.costUSD, 502.34, "mini's Team spend belongs to this Mac's Team instance")
    }

    func testRemapCollectsRemoteOnlyAccounts() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 50, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertEqual(remapped.remoteOnly.count, 1)
        XCTAssertEqual(remapped.remoteOnly.first?.baseProviderID, "claude")
        XCTAssertEqual(remapped.remoteOnly.first?.deviceNames, ["Mac mini"])
    }

    func testRemapLegacyV1DocumentKeepsSameCardMerge() {
        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [v1],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertEqual(remapped.histories.first?.cardID, "claude")
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testLocalDocumentPublishesInstancesWithIdentities() {
        let registry = makeRegistry()
        // Preload the cache; the store's init adopts cached snapshots as its local set.
        let cache = scratchCache()
        cache.store(snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)))
        cache.store(snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2)))
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("PublishDoc"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "instances sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testRemoteOnlyAccountFeedsTotalSpend() {
        let registry = makeRegistry()
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteTotal"),
            providerIdentityKeys: ["claude": maxKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: today, tokens: 1_000_000, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        let entry = dataStore.remoteOnlySpend[0]
        XCTAssertEqual(entry.provider.displayName, "Claude · Mac mini")

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [entry.provider],
            snapshots: [entry.provider.id: entry.snapshot]
        )
        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices[0].amountUSD, 42, accuracy: 0.001)
    }

    func testTotalSpendRanksBySizeAndKeepsFamilyColors() {
        let claude = ClaudeProvider.makeProvider(displayName: "Claude 1")
        let instance = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude 2")
        let remote = Provider(id: "claude@peer-ab12cd34", displayName: "Claude · Mac mini", icon: claude.icon)
        let codex = CodexProvider.makeProvider()

        func spendSnapshot(_ provider: Provider, dollars: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(
                    label: "Today",
                    values: [MetricValue(number: dollars, kind: .dollars, estimated: true)]
                )],
                refreshedAt: Date()
            )
        }

        // Plain size order — family membership is carried by color, not by grouping, and identity-
        // keyed sync makes the amounts (and therefore this order) identical on every Mac.
        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude, instance, remote, codex],
            snapshots: [
                claude.id: spendSnapshot(claude, dollars: 900),
                instance.id: spendSnapshot(instance, dollars: 150),
                remote.id: spendSnapshot(remote, dollars: 40),
                codex.id: spendSnapshot(codex, dollars: 300)
            ]
        )
        let names = total.projection(for: .cost).slices.map(\.provider.displayName)
        XCTAssertEqual(names, ["Claude 1", "Codex", "Claude 2", "Claude · Mac mini"])

        // Instances tint within the family hue — stable per id, never the fallback rainbow, and
        // distinct from the base card's brand color.
        let base = TotalSpendPalette.color(for: "claude")
        let tintA = TotalSpendPalette.color(for: "claude@f15456b0")
        let tintB = TotalSpendPalette.color(for: "claude@peer-ab12cd34")
        XCTAssertNotEqual(base, tintA)
        XCTAssertEqual(tintA, TotalSpendPalette.color(for: "claude@f15456b0"), "stable across calls")
        XCTAssertNotEqual(tintA, TotalSpendPalette.color(for: "codex@x"), "family hues don't cross")
        _ = tintB
    }

    // MARK: - Fixtures

    private func makeRegistry() -> WidgetRegistry {
        let claude = ClaudeProvider.makeProvider()
        let instance = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude 2")
        let descriptors = [
            WidgetDescriptor.usageTrend(provider: claude)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            WidgetDescriptor.usageTrend(provider: instance)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        ]
        return WidgetRegistry(providers: [claude, instance], descriptors: descriptors)
    }

    private func scratchCache() -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: makeScratchDefaults("Cache"), storageKey: "snapshots", ttl: 600)
    }

    private func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.PeerIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeDocument(
        deviceName: String = "Peer",
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString,
            deviceName: deviceName,
            updatedAt: Date(),
            providers: providers,
            identities: identities
        )
    }

    private func history(day: String, tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: tokens, costUSD: cost)]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    private func snapshot(providerID: String, history: ProviderUsageHistory) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            providerID: providerID,
            displayName: providerID,
            lines: [],
            refreshedAt: Date()
        )
        snapshot.usageHistory = history
        return snapshot
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
