import XCTest
@testable import OpenUsage

/// Covers the launch-time account guard on the snapshot cache (v9): when a claude/codex card's
/// CURRENT account identity is known, a cached entry only paints if the account that produced it
/// (`producedByIdentityKey` stamp) matches. After an account swap at the same home the card id still
/// matches, so without the stamp check the previous account's limits/plan would show under the new
/// account until the first successful refresh. A card whose current identity is unresolved keeps its
/// cache (behavior identical to before the guard), and non-account providers are untouched.
@MainActor
final class WidgetDataStoreAccountCacheTests: XCTestCase {
    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "WidgetDataStoreAccountCacheTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark("codex"))
    }

    private func snapshot(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: Date()
        )
    }

    private func makeStore(
        providers: [Provider],
        cache: ProviderSnapshotCache,
        defaults: UserDefaults,
        identityKeys: [String: String]
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: []),
            providers: [],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: identityKeys
        )
    }

    /// A matching stamp keeps the entry: same account across launches, cache paints as always.
    func testMatchingStampKeepsCachedEntryAtLaunch() {
        let defaults = makeUserDefaults("match")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")

        let store = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-A"]
        )
        XCTAssertNotNil(store.snapshots["claude"])
    }

    /// A mismatched stamp drops ONLY that entry: the swapped card starts blank until its refresh,
    /// while the other family's card with a matching stamp keeps painting.
    func testMismatchedStampDropsOnlyThatEntry() {
        let defaults = makeUserDefaults("mismatch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")
        cache.store(snapshot("codex", used: 50), producedByIdentityKey: "acct-B")

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW", "codex": "acct-B"]
        )
        XCTAssertNil(store.snapshots["claude"], "swapped account's cached snapshot must not paint")
        XCTAssertNotNil(store.snapshots["codex"], "unswapped card must keep its cache")
    }

    /// An unstamped entry on an account-aware card whose current identity IS known was written while
    /// the identity was unresolved — unattributable, so conservatively dropped.
    func testNilStampWithKnownIdentityIsDropped() {
        let defaults = makeUserDefaults("nil-stamp")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("codex", used: 40))

        let store = makeStore(
            providers: [provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["codex": "acct-A"]
        )
        XCTAssertNil(store.snapshots["codex"])
    }

    /// A card whose CURRENT identity is unresolved (logged out, keyring-mode Codex) can't verify a
    /// stamp either way — it keeps its cache, exactly as before the guard existed. Dropping here
    /// would blank the card at every launch for users whose identity never resolves.
    func testUnresolvedCurrentIdentityKeepsEntry() {
        let defaults = makeUserDefaults("no-identity")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        cache.store(snapshot("codex", used: 50))

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["claude"])
        XCTAssertNotNil(store.snapshots["codex"])
    }

    /// Non-account providers are untouched by the guard: their entries load with or without a stamp
    /// (they never carry one in production, but even a stray stamp must not gate them).
    func testNonAccountProviderLoadsRegardlessOfStamp() {
        let defaults = makeUserDefaults("non-account")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("cursor", used: 40))
        cache.store(snapshot("grok", used: 50), producedByIdentityKey: "stray-stamp")

        let store = makeStore(
            providers: [provider("cursor"), provider("grok")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["cursor"])
        XCTAssertNotNil(store.snapshots["grok"])
    }

    /// A TTL-fresh entry with a mismatched stamp must not short-circuit `refresh` as a cache hit —
    /// under persisted freshness (the one-shot CLI) that would copy the previous account's snapshot
    /// back in. A matching stamp keeps the normal cache-hit path.
    func testRefreshNeverCacheHitsAMismatchedStampEntry() async {
        let defaults = makeUserDefaults("refresh-gate")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")

        let swapped = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW"]
        )
        // No provider runtime is registered, so passing the cache gate surfaces as `.skipped` (a
        // fetch attempt), while honoring the stale entry would surface as `.cacheHit`.
        let gated = await swapped.refresh(providerID: "claude")
        XCTAssertEqual(gated, .skipped, "a mismatched stamp must fall through to a real fetch")

        let sameAccount = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-OLD"]
        )
        let honored = await sameAccount.refresh(providerID: "claude")
        XCTAssertEqual(honored, .cacheHit)
    }

    /// The single predicate every read path shares (`hasStaleAccountStamp`): true only when an entry
    /// exists, the current identity is known, and the stamp fails to name it.
    func testHasStaleAccountStampSemantics() {
        let defaults = makeUserDefaults("predicate")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"), "no entry, nothing to distrust")

        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"))
        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: nil), "unresolved identity can't prove staleness")
        XCTAssertTrue(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-B"))

        cache.store(snapshot("claude", used: 41))
        XCTAssertTrue(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"), "an unstamped entry is unattributable")
    }

    /// A refresh writes the card's launch-resolved identity as the stamp, and a nil identity CLEARS
    /// any prior stamp — leaving the old account's stamp would falsely bless the new snapshot.
    func testStoreStampsAndClearsProducerIdentity() {
        let defaults = makeUserDefaults("stamp-write")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "acct-A")

        cache.store(snapshot("claude", used: 41))
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))
    }
}
