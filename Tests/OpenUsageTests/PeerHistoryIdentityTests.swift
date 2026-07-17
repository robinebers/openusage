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
        XCTAssertEqual(remapped.remoteOnly.first?.devices.map(\.name), ["Mac mini"])
    }

    func testRemapNamespacesTheSameOpaqueIdentityByProviderFamily() {
        let codexDoc = makeDocument(
            providers: ["codex": history(day: "2026-07-16", tokens: 50, cost: 42)],
            identities: ["codex": maxKey]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [codexDoc],
            localIdentityByCardID: ["claude": maxKey]
        )

        XCTAssertTrue(remapped.histories.isEmpty, "a Codex identity must never route into a Claude card")
        XCTAssertEqual(remapped.remoteOnly.map(\.baseProviderID), ["codex"])
    }

    func testRemoteOnlyDevicesStayDistinctWhenTheirNamesMatch() {
        let identity = "uuid-other|org-x"
        let first = makeDocument(
            deviceID: "mac-a",
            deviceName: "MacBook Pro",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": identity]
        )
        let second = makeDocument(
            deviceID: "mac-b",
            deviceName: "MacBook Pro",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2)],
            identities: ["claude@ab12cd34": identity]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [first, second],
            localIdentityByCardID: ["claude": maxKey]
        )

        XCTAssertEqual(remapped.remoteOnly.count, 1)
        XCTAssertEqual(Set(remapped.remoteOnly[0].devices.map(\.id)), ["mac-a", "mac-b"])
        XCTAssertEqual(remapped.remoteOnly[0].devices.map(\.name), ["MacBook Pro", "MacBook Pro"])

        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("DuplicateDeviceNames"),
            providerIdentityKeys: ["claude": maxKey]
        )
        dataStore.setPeerHistoryDocuments([first, second], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.first?.provider.displayName, "Claude · 2 other Macs")
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

    func testLocalDocumentPublishesInstancesWithIdentitiesAfterAuthoritativeScans() async {
        let registry = makeRegistry()
        let defaults = makeScratchDefaults("PublishDoc")
        let snapshots = [
            snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2))
        ]
        let runtimes = zip(registry.providers, snapshots).map { provider, snapshot in
            TestProviderRuntime(
                provider: provider,
                descriptors: registry.descriptors(for: provider.id),
                snapshot: snapshot
            )
        }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        await dataStore.refreshAll(force: true)

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "instances sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testAccountAwareFamiliesWithholdHistoryWhenCurrentIdentityIsUnknown() async {
        let providers = [
            Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude")),
            Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex")),
            Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        ]
        let descriptors = providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let runtimes = providers.map { provider in
            TestProviderRuntime(
                provider: provider,
                descriptors: registry.descriptors(for: provider.id),
                snapshot: snapshot(
                    providerID: provider.id,
                    history: history(day: "2026-07-16", tokens: 10, cost: 1)
                )
            )
        }
        let defaults = makeScratchDefaults("UnknownCurrentIdentity")
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            providerIdentityKeys: [:]
        )

        await dataStore.refreshAll(force: true)

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac")
        XCTAssertNil(document.providers["claude"])
        XCTAssertNil(document.providers["codex"])
        XCTAssertNotNil(document.providers["grok"], "identityless providers keep legacy same-card export")
    }

    func testDefaultSwapWithholdsOldCachedHistoryUntilTheNewIdentityHasAnAuthoritativeScan() async {
        let registry = makeRegistry()
        let provider = registry.providers[0]
        let descriptors = registry.descriptors(for: provider.id)
        let defaults = makeScratchDefaults("SwapBinding")
        let oldHistory = history(day: "2026-07-16", tokens: 10, cost: 1)
        let oldRuntime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: snapshot(providerID: provider.id, history: oldHistory)
        )
        let oldStore = WidgetDataStore(
            registry: registry,
            providers: [oldRuntime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            providerIdentityKeys: [provider.id: maxKey]
        )
        _ = await oldStore.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(oldStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").identities?[provider.id], maxKey)

        let noHistory = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: Date()
        )
        let newHistory = history(day: "2026-07-16", tokens: 20, cost: 2)
        let swappedRuntime = TogglingProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            first: noHistory,
            second: snapshot(providerID: provider.id, history: newHistory)
        )
        let swappedStore = WidgetDataStore(
            registry: registry,
            providers: [swappedRuntime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            providerIdentityKeys: [provider.id: teamKey]
        )

        XCTAssertNil(
            swappedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id],
            "the startup cache belongs to the prior identity"
        )
        _ = await swappedStore.refresh(providerID: provider.id, force: true)
        XCTAssertNil(
            swappedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id],
            "a live-limits success that preserved old history does not establish a new binding"
        )

        _ = await swappedStore.refresh(providerID: provider.id, force: true)
        let freshDocument = swappedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac")
        XCTAssertEqual(freshDocument.identities?[provider.id], teamKey)
        XCTAssertEqual(freshDocument.providers[provider.id]?.series.daily.first?.costUSD, 2)

        swappedStore.updateProviderIdentityKeys([provider.id: "uuid-me|org-third"])
        XCTAssertNil(
            swappedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id],
            "an in-process identity change invalidates the prior binding immediately"
        )
    }

    func testDefaultSwapDoesNotAddOldCachedHistoryToMatchingPeerHistory() async throws {
        let registry = makeRegistry()
        let provider = registry.providers[0]
        let descriptors = registry.descriptors(for: provider.id)
        let defaults = makeScratchDefaults("SwapPeerMerge")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let today = dayKey(Date())
        let oldHistory = history(day: today, tokens: 10, cost: 1)
        var oldSnapshot = snapshot(providerID: provider.id, history: oldHistory)
        oldSnapshot.lines = [
            .values(label: "Today", values: [MetricValue(number: 1, kind: .dollars, estimated: true)])
        ]
        let oldStore = WidgetDataStore(
            registry: registry,
            providers: [TestProviderRuntime(
                provider: provider,
                descriptors: descriptors,
                snapshot: oldSnapshot
            )],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: [provider.id: maxKey]
        )
        _ = await oldStore.refresh(providerID: provider.id, force: true)

        let swappedStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: [provider.id: teamKey]
        )
        XCTAssertEqual(
            try todayCost(in: swappedStore.snapshots[provider.id]),
            1,
            "without a peer replacement the old account remains visible as stale local UI"
        )

        let peerHistory = history(day: today, tokens: 20, cost: 2)
        swappedStore.setPeerHistoryDocuments([
            makeDocument(
                providers: [provider.id: peerHistory],
                identities: [provider.id: teamKey]
            )
        ], ownDeviceID: "this-mac")

        XCTAssertEqual(
            try todayCost(in: swappedStore.snapshots[provider.id]),
            2,
            "the matching peer account must replace the unsafe local cache, not add to it"
        )
    }

    func testPathIdentityUpgradeBindsOnlyHistoryScannedThisSession() async {
        let registry = makeRegistry()
        let provider = registry.providers[0]
        let descriptors = registry.descriptors(for: provider.id)
        let pathIdentity = ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: "/tmp/codex-home")
        let realIdentity = "account-real"
        let currentHistory = history(day: "2026-07-16", tokens: 20, cost: 2)

        let scannedDefaults = makeScratchDefaults("PathUpgradeScanned")
        let scannedStore = WidgetDataStore(
            registry: registry,
            providers: [TestProviderRuntime(
                provider: provider,
                descriptors: descriptors,
                snapshot: snapshot(providerID: provider.id, history: currentHistory)
            )],
            cache: ProviderSnapshotCache(userDefaults: scannedDefaults, storageKey: "snapshots"),
            defaults: scannedDefaults,
            providerIdentityKeys: [provider.id: pathIdentity]
        )
        _ = await scannedStore.refresh(providerID: provider.id, force: true)
        XCTAssertNil(scannedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id])

        scannedStore.updateProviderIdentityKey(realIdentity, for: provider.id)
        let upgraded = scannedStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac")
        XCTAssertEqual(upgraded.identities?[provider.id], realIdentity)
        XCTAssertEqual(upgraded.providers[provider.id]?.series.daily.first?.costUSD, 2)

        let cachedDefaults = makeScratchDefaults("PathUpgradeCachedOnly")
        let cache = ProviderSnapshotCache(userDefaults: cachedDefaults, storageKey: "snapshots")
        cache.store(snapshot(providerID: provider.id, history: currentHistory))
        let cachedOnlyStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: cachedDefaults,
            providerIdentityKeys: [provider.id: pathIdentity]
        )
        cachedOnlyStore.updateProviderIdentityKey(realIdentity, for: provider.id)
        XCTAssertNil(
            cachedOnlyStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id],
            "an identity upgrade cannot bless a cache that was not scanned in this process"
        )
    }

    func testIdentityResolvedDuringFirstRefreshBindsOnlyTheReturnedHistory() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let resolvedIdentity = "account-first-refresh"
        let currentHistory = history(day: "2026-07-16", tokens: 20, cost: 2)

        var dataStore: WidgetDataStore?
        let runtime = IdentityResolvingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: snapshot(providerID: provider.id, history: currentHistory)
        ) {
            dataStore?.updateProviderIdentityKey(resolvedIdentity, for: provider.id)
        }
        let defaults = makeScratchDefaults("FirstRefreshIdentityResolution")
        dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            providerIdentityKeys: [:]
        )

        _ = await dataStore?.refresh(providerID: provider.id, force: true)

        let firstRefresh = dataStore?.localHistoryDocument(deviceID: "dev", deviceName: "Mac")
        XCTAssertEqual(firstRefresh?.identities?[provider.id], resolvedIdentity)
        XCTAssertEqual(firstRefresh?.providers[provider.id]?.series.daily.first?.costUSD, 2)

        let cachedDefaults = makeScratchDefaults("CachedNilIdentityResolution")
        let cache = ProviderSnapshotCache(userDefaults: cachedDefaults, storageKey: "snapshots")
        cache.store(snapshot(providerID: provider.id, history: currentHistory))
        let cachedOnlyStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: cachedDefaults,
            providerIdentityKeys: [:]
        )
        cachedOnlyStore.updateProviderIdentityKey(resolvedIdentity, for: provider.id)
        XCTAssertNil(
            cachedOnlyStore.localHistoryDocument(deviceID: "dev", deviceName: "Mac").providers[provider.id],
            "resolving an identity cannot bless history loaded only from the snapshot cache"
        )
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

    func testRemoteOnlySpendRespectsBaseEnablementAndMachineLocalScope() {
        var claudeEnabled = false
        let registry = makeRegistry()
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteEnablement"),
            isProviderEnabled: { providerID in providerID != "claude" || claudeEnabled },
            providerIdentityKeys: ["claude": maxKey]
        )
        let today = dayKey(Date())
        let remoteClaude = makeDocument(
            providers: ["claude@ab12cd34": history(day: today, tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([remoteClaude], ownDeviceID: "this-mac")
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty)

        claudeEnabled = true
        dataStore.providerEnablementDidChange()
        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)

        let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let accountWideRegistry = WidgetRegistry(
            providers: [cursor],
            descriptors: [
                WidgetDescriptor.usageTrend(provider: cursor)
                    .exportingHistory(scope: .accountWide, estimatedCost: true, sourceNote: "test")
            ]
        )
        let accountWideStore = WidgetDataStore(
            registry: accountWideRegistry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteScope"),
            providerIdentityKeys: ["cursor": "cursor-local"]
        )
        let remoteCursor = makeDocument(
            providers: ["cursor@ab12cd34": history(day: today, tokens: 10, cost: 1)],
            identities: ["cursor@ab12cd34": "cursor-remote"]
        )
        accountWideStore.setPeerHistoryDocuments([remoteCursor], ownDeviceID: "this-mac")
        XCTAssertTrue(accountWideStore.remoteOnlySpend.isEmpty)
    }

    func testTotalSpendTooltipNamesRemoteOnlyContributors() {
        let tooltip = TotalSpendCard.contributorTooltip(
            names: ["Claude", "Codex", "Claude · Mac mini"]
        )

        XCTAssertTrue(tooltip.contains("Claude"))
        XCTAssertTrue(tooltip.contains("Codex"))
        XCTAssertTrue(tooltip.contains("Claude · Mac mini"))
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
        deviceID: String = UUID().uuidString,
        deviceName: String = "Peer",
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
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

    private func todayCost(in snapshot: ProviderSnapshot?) throws -> Double {
        let line = try XCTUnwrap(snapshot?.line(label: "Today"))
        guard case .values(_, let values, _, _, _, _) = line else {
            XCTFail("expected a Today values line")
            return 0
        }
        return try XCTUnwrap(values.first(where: { $0.kind == .dollars })?.number)
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

@MainActor
private final class IdentityResolvingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let snapshot: ProviderSnapshot
    private let resolveIdentity: () -> Void

    init(
        provider: Provider,
        descriptors: [WidgetDescriptor],
        snapshot: ProviderSnapshot,
        resolveIdentity: @escaping () -> Void
    ) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
        self.resolveIdentity = resolveIdentity
    }

    func refresh() async -> ProviderSnapshot {
        resolveIdentity()
        return snapshot
    }
}
