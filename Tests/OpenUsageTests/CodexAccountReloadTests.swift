import XCTest
@testable import OpenUsage

/// The live rebuild of the Codex cards after a login is added or removed in Customize: the family
/// is swapped in its place, the layout seeds the new card as a launch would, the data store drops
/// the old card and paints the new one from its own cache only, and a refresh that outlived its
/// runtime publishes nothing.
@MainActor
final class CodexAccountReloadTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures

    private func assemble(
        files: FakeFiles, directories: [String: [String]] = [:], managed: [CodexManagedLogin] = [],
        families: Set<String> = ["codex"], defaults: UserDefaults? = nil
    ) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(),
            homeDirectory: { Fixtures.home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults ?? makeScratchDefaults()),
            families: families,
            managedCodexLogins: managed,
            listCodexHomeDirectories: { directories[$0] ?? [] }
        )
    }

    private static let managedRoot = "/Users/dev/Library/Application Support/OpenUsage/codex-accounts/com.example"

    private func managedLogin(home: String, identityKey: String) -> CodexManagedLogin {
        CodexManagedLogin(id: UUID(), home: home, identityKey: identityKey, createdAt: Date(), lastSignedInAt: Date())
    }

    private func runtime(
        _ id: String, name: String? = nil, descriptors: [WidgetDescriptor] = [], value: Double = 1
    ) -> TestProviderRuntime {
        let provider = Provider(id: id, displayName: name ?? id, icon: .providerMark("codex"))
        return TestProviderRuntime(
            provider: provider, descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: id, displayName: provider.displayName,
                lines: [.progress(label: "Session", used: value, limit: 100, format: .percent)]
            )
        )
    }

    private func layoutDefaults(for registry: WidgetRegistry) -> LayoutDefaultSet {
        let ids = registry.providers.map(\.id)
        return LayoutDefaultSet(
            metricIDs: DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: ids),
            migrationBaselineMetricIDs: DefaultLayout.migrationBaselineMetricIDs,
            pinnedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.pinnedMetricIDs, providerIDs: ids),
            expandedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.expandedMetricIDs, providerIDs: ids)
        )
    }

    // MARK: - Catalog

    func testTheCodexFamilyIsSwappedInItsPlace() async {
        let assembly = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ]))
        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
        let before = providers.map(\.provider.id)
        XCTAssertEqual(before.filter { ProviderAccountID.family(of: $0) == "codex" }, ["codex"])
        // The family's own builder yields the same slice the catalog does.
        XCTAssertEqual(ProviderCatalog.makeCodexProviders(assembly.codex).map(\.provider.id), ["codex"])

        let replaced = ProviderCatalog.replacingCodexProviders(
            in: providers, with: [runtime("codex"), runtime("codex@b")]
        ).map(\.provider.id)

        let codexAt = before.firstIndex(of: "codex")!
        XCTAssertEqual(replaced, Array(before[..<codexAt]) + ["codex", "codex@b"] + Array(before[(codexAt + 1)...]))
        XCTAssertEqual(replaced.first, "claude")
        XCTAssertEqual(replaced[codexAt + 2], "cursor")
    }

    func testTheLastCodexCardStandingIsNamedPlainCodexAgain() async {
        // The registry remembers the install ran with two accounts, so the lone survivor stays a
        // scoped card — but on the dashboard it reads "Codex", as it did before any account was added.
        let defaults = makeScratchDefaults("CodexReloadLoneCard")
        let home = "\(Self.managedRoot)/B"
        let two = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ]), managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")], defaults: defaults)
        XCTAssertEqual(
            ProviderCatalog.makeCodexProviders(two.codex).map(\.provider.displayName),
            ["Codex: alice@test", "Codex: bob@test"]
        )

        let one = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ]), defaults: defaults)

        XCTAssertEqual(one.codexCards.map(\.id), ["codex"])
        XCTAssertEqual(one.identityKeysByCard["codex"], "acct-a|alice@test", "the lone card lost its scope")
        XCTAssertEqual(ProviderCatalog.makeCodexProviders(one.codex).map(\.provider.displayName), ["Codex"])
    }

    // MARK: - Layout

    func testReplacingTheRegistrySeedsANewCardLikeALaunchAndKeepsTheUsersChoices() async {
        let defaults = makeScratchDefaults("CodexReloadLayout")
        let one = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ]), defaults: defaults)
        let home = "\(Self.managedRoot)/B"
        let two = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ]), managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")], defaults: defaults)
        let single = WidgetRegistry.from(ProviderCatalog.makeCodexProviders(one.codex))
        let pair = WidgetRegistry.from(ProviderCatalog.makeCodexProviders(two.codex))
        let newCard = try! XCTUnwrap(pair.providers.map(\.id).first { $0 != "codex" })
        let store = LayoutStore(
            registry: single, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: layoutDefaults(for: single).metricIDs,
            defaultPinnedMetricIDs: layoutDefaults(for: single).pinnedMetricIDs,
            defaultExpandedMetricIDs: layoutDefaults(for: single).expandedMetricIDs
        )
        // A choice the user made on the existing card must survive the rebuild.
        store.setMetricEnabled("codex.session", false)
        XCTAssertTrue(store.canUndo)

        store.replaceRegistry(pair, defaults: layoutDefaults(for: pair))

        XCTAssertEqual(store.orderedProviderIDs(), ["codex", newCard])
        XCTAssertFalse(store.isMetricEnabled("codex.session"), "the user's choice was reset")
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"))
        // The new card arrives with its family's defaults: enabled metrics, pins, and caret placement.
        XCTAssertTrue(store.isMetricEnabled("\(newCard).session"))
        XCTAssertTrue(store.isMetricEnabled("\(newCard).weekly"))
        // Pins seed on a fresh install only; a saved pin set wins, as at a launch.
        XCTAssertFalse(store.pinnedMetricIDs.contains("\(newCard).session"))
        XCTAssertTrue(store.expandedMetricIDs.contains("\(newCard).today"))
        XCTAssertFalse(store.expandedMetricIDs.contains("\(newCard).session"))
        XCTAssertFalse(store.canUndo, "undo must start fresh with the new provider set")

        // Removing the account takes its widgets, pins, and caret membership with it.
        store.replaceRegistry(single, defaults: layoutDefaults(for: single))

        XCTAssertEqual(store.orderedProviderIDs(), ["codex"])
        XCTAssertFalse(store.placed.contains { $0.descriptorID.hasPrefix("\(newCard).") })
        XCTAssertFalse(store.pinnedMetricIDs.contains { $0.hasPrefix("\(newCard).") })
        XCTAssertFalse(store.expandedMetricIDs.contains { $0.hasPrefix("\(newCard).") })
        XCTAssertFalse(store.isMetricEnabled("codex.session"))
    }

    // MARK: - Data store

    func testReplacingProvidersDropsTheRemovedCardAndPaintsTheNewOneFromItsOwnCacheOnly() async {
        let defaults = makeScratchDefaults("CodexReloadData")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let old = runtime("codex@old")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [old.provider], descriptors: []), providers: [old],
            cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex@old": "acct-a|alice@test"], accountAwareFamilies: ["codex"]
        )
        await store.refreshAll()
        XCTAssertNotNil(store.snapshots["codex@old"])
        // Two cached entries for cards about to appear: one its own account wrote, one another's.
        let own = runtime("codex@own", value: 42)
        let foreign = runtime("codex@foreign", value: 7)
        cache.store(own.snapshot, producedByIdentityKey: "acct-b|bob@test")
        cache.store(foreign.snapshot, producedByIdentityKey: "acct-x|someone@test")

        store.replaceProviders(
            [own, foreign],
            registry: WidgetRegistry(providers: [own.provider, foreign.provider], descriptors: []),
            providerIdentityKeys: ["codex@own": "acct-b|bob@test", "codex@foreign": "acct-c|carol@test"],
            accountAwareFamilies: ["codex"]
        )

        XCTAssertNil(store.snapshots["codex@old"], "the removed card kept its rendered snapshot")
        XCTAssertEqual(store.snapshots["codex@own"], own.snapshot, "the new card's own cache did not paint")
        XCTAssertNil(store.snapshots["codex@foreign"], "another account's cache painted under the new card")
        XCTAssertEqual(store.providerIdentityKeys["codex@own"], "acct-b|bob@test")
        XCTAssertEqual(store.accountAwareFamilies, ["codex"])
    }

    func testACardThatChangedHandsKeepsNothingOfItsOldOwner() async {
        // The only managed account held the bare `codex` id. After its Remove the plain fallback
        // card has the same id but names no account: the removed account's limits and history must
        // not stay on screen, in the API, or in the iCloud export under that id.
        let defaults = makeScratchDefaults("CodexReloadChangedHands")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let trend = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "")
        let registry = WidgetRegistry(providers: [provider], descriptors: [trend])
        let bob = TestProviderRuntime(
            provider: provider, descriptors: [trend],
            snapshot: ProviderSnapshot(
                providerID: "codex", displayName: "Codex",
                lines: [.progress(label: "Session", used: 73, limit: 100, format: .percent)],
                usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
            )
        )
        let store = WidgetDataStore(
            registry: registry, providers: [bob], cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "acct-b|bob@test"], accountAwareFamilies: ["codex"]
        )
        await store.refreshAll()
        XCTAssertNotNil(store.localHistoryDocument(deviceID: "d", deviceName: "mac").providers["codex"])

        // Remove: the service forgets the card's cache, then the rebuild hands the id to a plain card.
        store.forgetCachedSnapshots(providerIDs: ["codex"])
        let plain = runtime("codex", name: "Codex", descriptors: [trend], value: 1)
        store.replaceProviders([plain], registry: registry, providerIdentityKeys: [:], accountAwareFamilies: ["codex"])

        XCTAssertNil(store.snapshots["codex"], "the removed account's snapshot stayed on the fallback card")
        XCTAssertNil(store.localHistoryDocument(deviceID: "d", deviceName: "mac").providers["codex"], "the removed account's history was exported")
        XCTAssertNil(store.errorMessage(for: "codex"))

        // The other direction: the identity-less card fetched, then an account took the id. Its
        // own cache is stamped for no account, so the new owner does not paint from it either.
        await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(store.snapshots["codex"], plain.snapshot)
        let carol = runtime("codex", name: "Codex", descriptors: [trend], value: 2)
        store.replaceProviders([carol], registry: registry, providerIdentityKeys: ["codex": "acct-c|carol@test"], accountAwareFamilies: ["codex"])
        XCTAssertNil(store.snapshots["codex"], "the fallback card's numbers painted under the new account")

        // Same owner before and after: the snapshot stays.
        await store.refresh(providerID: "codex", force: true)
        store.replaceProviders([runtime("codex", name: "Codex", descriptors: [trend], value: 3)], registry: registry, providerIdentityKeys: ["codex": "acct-c|carol@test"], accountAwareFamilies: ["codex"])
        XCTAssertEqual(store.snapshots["codex"], carol.snapshot)
    }

    func testARenewedCardFetchesAtOnceWhileItsOldFetchIsStillRunning() async {
        // Sign In Again rebuilds a card whose periodic fetch is still out: the rebuilt runtime must
        // be fetched now, not blocked by the old fetch's in-flight entry, and the old result must
        // not land on top of the fresh one when it finally returns.
        let defaults = makeScratchDefaults("CodexReloadRenewal")
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let stale = ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [.progress(label: "Session", used: 99, limit: 100, format: .percent)]
        )
        let held = HeldProviderRuntime(provider: provider, snapshot: stale)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []), providers: [held],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        let pass = Task { await store.refreshAll() }
        for _ in 0..<1_000 where !held.didStart { await Task.yield() }
        XCTAssertTrue(held.didStart)

        let fresh = runtime("codex", name: "Codex", value: 5)
        store.replaceProviders(
            [fresh], registry: WidgetRegistry(providers: [provider], descriptors: []),
            providerIdentityKeys: [:], accountAwareFamilies: []
        )
        XCTAssertFalse(store.refreshingProviderIDs.contains("codex"), "the old fetch kept the rebuilt card busy")
        let outcome = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(outcome, .refreshed, "the rebuilt card was not fetched")
        // The batch is still open, so the rendered set follows once it ends; the local set is live.
        XCTAssertEqual(store.localSnapshots["codex"], fresh.snapshot)

        held.complete()
        await pass.value
        XCTAssertEqual(store.snapshots["codex"], fresh.snapshot, "the old fetch overwrote the renewed card")
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty, "a spinner outlived both fetches")
    }

    func testARemovedCardReleasesItsSpinnerAtOnce() async {
        // Card B is removed while its periodic fetch is still out. Its id must leave the shared
        // spinner set right away — the footer's Refresh follows that set — and its late result
        // must land nowhere.
        let defaults = makeScratchDefaults("CodexReloadRemovedSpinner")
        let a = runtime("codex", name: "Codex", value: 1)
        let b = Provider(id: "codex@b", displayName: "Codex: bob@test", icon: .providerMark("codex"))
        let held = HeldProviderRuntime(provider: b, snapshot: ProviderSnapshot(providerID: "codex@b", displayName: b.displayName, lines: []))
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [a.provider, b], descriptors: []), providers: [a, held],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        let pass = Task { await store.refreshAll() }
        for _ in 0..<1_000 where !held.didStart { await Task.yield() }
        XCTAssertTrue(store.refreshingProviderIDs.contains("codex@b"))

        store.replaceProviders(
            [a], registry: WidgetRegistry(providers: [a.provider], descriptors: []),
            providerIdentityKeys: [:], accountAwareFamilies: []
        )

        XCTAssertFalse(store.refreshingProviderIDs.contains("codex@b"), "the removed card kept the spinner")
        held.complete()
        await pass.value
        XCTAssertNil(store.snapshots["codex@b"])
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
    }

    func testRebuiltCardsAreFetchedIndependently() async {
        // A slow first card must not hold the renewed second card's fetch: each rebuilt card fetches
        // in its own task, and the call returns before any of them finishes.
        let defaults = makeScratchDefaults("CodexReloadIndependent")
        let slow = Provider(id: "codex", displayName: "Codex: alice@test", icon: .providerMark("codex"))
        let held = HeldProviderRuntime(provider: slow, snapshot: ProviderSnapshot(providerID: "codex", displayName: slow.displayName, lines: []))
        let renewed = runtime("codex@b", name: "Codex: bob@test", value: 9)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [slow, renewed.provider], descriptors: []), providers: [held, renewed],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )

        store.refreshRebuilt(providerIDs: ["codex", "codex@b"])

        for _ in 0..<1_000 where store.localSnapshots["codex@b"] == nil { await Task.yield() }
        XCTAssertEqual(store.localSnapshots["codex@b"], renewed.snapshot, "the second card waited for the first")
        XCTAssertTrue(held.didStart)
        XCTAssertNil(store.localSnapshots["codex"])
        held.complete()
        for _ in 0..<1_000 where store.localSnapshots["codex"] == nil { await Task.yield() }
        XCTAssertNotNil(store.localSnapshots["codex"])
    }

    func testARenameDoesNotCountAsThisSessionsFetch() async {
        // A card painted from the previous session's cache, renamed by an account change before it
        // fetched: the rename must not make that entry pass for this session's fetch, or the card
        // keeps last session's numbers for a whole interval once it is turned on.
        let defaults = makeScratchDefaults("CodexReloadRenameFreshness")
        let named = Provider(id: "codex", displayName: "Codex: alice@test", icon: .providerMark("codex"))
        let snapshot = ProviderSnapshot(providerID: "codex", displayName: named.displayName,
                                        lines: [.progress(label: "Session", used: 3, limit: 100, format: .percent)])
        // Session 1 fetched and persisted the entry a moment ago.
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").store(snapshot, producedByIdentityKey: "acct-a|alice@test")

        // Session 2: painted at launch, not fetched yet.
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let counting = CountingProviderRuntime(provider: named, descriptors: [], snapshot: snapshot)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [named], descriptors: []), providers: [counting],
            cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "acct-a|alice@test"], accountAwareFamilies: ["codex"]
        )
        XCTAssertEqual(store.snapshots["codex"]?.displayName, "Codex: alice@test")
        XCTAssertNil(cache.snapshot(providerID: "codex"), "a launch-painted entry is never fresh")

        let plain = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        store.replaceProviders(
            [CountingProviderRuntime(provider: plain, descriptors: [], snapshot: snapshot)],
            registry: WidgetRegistry(providers: [plain], descriptors: []),
            providerIdentityKeys: ["codex": "acct-a|alice@test"], accountAwareFamilies: ["codex"]
        )
        XCTAssertEqual(store.snapshots["codex"]?.displayName, "Codex")
        XCTAssertEqual(ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").loadSnapshots(providerIDs: ["codex"])["codex"]?.displayName, "Codex")
        XCTAssertNil(cache.snapshot(providerID: "codex"), "the rename passed for this session's fetch")

        let outcome = await store.refresh(providerID: "codex")
        XCTAssertEqual(outcome, .refreshed, "the first fetch of the session was skipped")
    }

    func testTheRebuildFetchesARenewedCardPastItsFreshCache() async {
        // The card fetched fine this session, then its login lapsed and a forced refresh recorded
        // the error while that fetch's cache entry is still fresh. After Sign In Again the rebuild
        // must fetch for real: a plain refresh would hit the cache and keep the old login's error.
        let defaults = makeScratchDefaults("CodexReloadRenewalError")
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let registry = WidgetRegistry(providers: [provider], descriptors: [])
        let store = WidgetDataStore(
            registry: registry, providers: [runtime("codex", name: "Codex", value: 3)],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        await store.refreshAll()

        let lapsed = TestProviderRuntime(
            provider: provider, descriptors: [],
            snapshot: ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
        )
        store.replaceProviders([lapsed], registry: registry, providerIdentityKeys: [:], accountAwareFamilies: [])
        await store.refresh(providerID: "codex", force: true)
        XCTAssertNotNil(store.errorMessage(for: "codex"))
        let plain = await store.refresh(providerID: "codex")
        XCTAssertEqual(plain, .cacheHit, "the error must stand on a fresh cache for this test to mean anything")

        let renewed = CountingProviderRuntime(
            provider: provider, descriptors: [],
            snapshot: ProviderSnapshot(providerID: "codex", displayName: "Codex",
                                       lines: [.progress(label: "Session", used: 4, limit: 100, format: .percent)])
        )
        store.replaceProviders([renewed], registry: registry, providerIdentityKeys: [:], accountAwareFamilies: [])
        store.refreshRebuilt(providerIDs: ["codex"])
        for _ in 0..<1_000 where store.errorMessage(for: "codex") != nil { await Task.yield() }

        XCTAssertEqual(renewed.refreshCount, 1, "the rebuild did not fetch the renewed login")
        XCTAssertNil(store.errorMessage(for: "codex"))
        XCTAssertEqual(store.snapshots["codex"], renewed.snapshot)
    }

    func testARetainedSnapshotTakesItsCardsNewName() async {
        // The last extra account went: the survivor is "Codex" again. Its snapshot, which the local
        // API and the CLI serialize by name, must follow at once, in memory and on disk.
        let defaults = makeScratchDefaults("CodexReloadRename")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let named = Provider(id: "codex", displayName: "Codex: alice@test", icon: .providerMark("codex"))
        let alice = TestProviderRuntime(
            provider: named, descriptors: [],
            snapshot: ProviderSnapshot(providerID: "codex", displayName: named.displayName, lines: [])
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [named], descriptors: []), providers: [alice],
            cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "acct-a|alice@test"], accountAwareFamilies: ["codex"]
        )
        await store.refreshAll()
        XCTAssertEqual(store.snapshots["codex"]?.displayName, "Codex: alice@test")

        let plain = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        store.replaceProviders(
            [TestProviderRuntime(provider: plain, descriptors: [], snapshot: alice.snapshot)],
            registry: WidgetRegistry(providers: [plain], descriptors: []),
            providerIdentityKeys: ["codex": "acct-a|alice@test"], accountAwareFamilies: ["codex"]
        )

        XCTAssertEqual(store.snapshots["codex"]?.displayName, "Codex")
        XCTAssertEqual(store.snapshots["codex"]?.refreshedAt, alice.snapshot.refreshedAt, "the rename must not pass for a fetch")
        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots").loadSnapshots(providerIDs: ["codex"])
        XCTAssertEqual(persisted["codex"]?.displayName, "Codex")
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "codex"), "acct-a|alice@test")
    }

    func testARefreshStillRunningOnAReplacedRuntimePublishesNothing() async {
        let defaults = makeScratchDefaults("CodexReloadInFlight")
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let stale = ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [.progress(label: "Session", used: 99, limit: 100, format: .percent)]
        )
        let held = HeldProviderRuntime(provider: provider, snapshot: stale)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []), providers: [held],
            cache: cache, defaults: defaults
        )
        let pass = Task { await store.refreshAll() }
        for _ in 0..<1_000 where !held.didStart { await Task.yield() }
        XCTAssertTrue(held.didStart)

        // The same id is rebuilt on a new runtime (the plain card after an account change) while
        // the old one is still fetching.
        let fresh = runtime("codex", name: "Codex", value: 5)
        store.replaceProviders(
            [fresh], registry: WidgetRegistry(providers: [provider], descriptors: []),
            providerIdentityKeys: [:], accountAwareFamilies: []
        )
        held.complete()
        await pass.value

        XCTAssertNil(store.snapshots["codex"], "the old runtime's result was published under the rebuilt card")
        XCTAssertTrue(cache.loadSnapshots(providerIDs: ["codex"]).isEmpty, "the old runtime's result was cached")
        await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(store.snapshots["codex"], fresh.snapshot)
    }

    // MARK: - Account pass

    func testACodexOnlyPassReportsWhatItRead() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])

        let codexOnly = await assemble(files: files, families: ["codex"])
        XCTAssertEqual(codexOnly.readFamilies, ["codex"])
        XCTAssertTrue(codexOnly.claudeCards.isEmpty)

        // A pass that could not read Codex (login shell cold) has no cards, and says so: the live
        // reload must keep the launch state rather than take this for "no accounts".
        let skipped = await assemble(files: files, families: [])
        XCTAssertEqual(skipped.readFamilies, [])
        XCTAssertTrue(skipped.codexCards.isEmpty)
    }

    func testTwoWorkspacesOfOneEmailKeepTheWorkspaceInTheirNames() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "alice@test"),
            "/Users/dev/.codex-other/auth.json": Fixtures.codexAuth(accountID: "ACCT-C", email: "carol@test"),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work", ".codex-other"]])

        XCTAssertEqual(Set(assembly.codexCards.map(\.displayName)), [
            "Codex: alice@test (Workspace acct-a)", "Codex: alice@test (Workspace acct-b)", "Codex: carol@test",
        ])
    }
}

/// A runtime whose refresh waits until the test completes it, the way a slow fetch does.
@MainActor
private final class HeldProviderRuntime: ProviderRuntime {
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

    func hasLocalCredentials() async -> Bool { true }

    func complete() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
