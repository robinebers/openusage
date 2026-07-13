import XCTest
@testable import OpenUsage

/// Guards the in-memory write-through mirror: reads must reflect writes, a second store must not drop
/// the first, and the mirror must stay a cache over real persistence (a fresh instance reads from disk).
final class ProviderSnapshotCacheTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "providerSnapshotCache.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        // The second store must not drop the first, and reads come back from the mirror unchanged.
        XCTAssertEqual(cache.loadSnapshots(keys: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(key: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(key: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testWritesPersistForAFreshInstance() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now))

        // A fresh instance starts with an empty mirror, so the *display* read (`loadSnapshots`) proves the
        // write reached disk — the mirror is a cache over persistence, not a replacement for it. (The
        // freshness gate `snapshot(key:)` deliberately treats this disk-loaded value as stale; see
        // `testRelaunchLoadedSnapshotIsStaleEvenWithinTTL`.)
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(reloaded.loadSnapshots(keys: ["alpha"])["alpha"]?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// #697 core guarantee: a snapshot persisted by a *previous* session and reloaded on launch must not
    /// satisfy the refresh gate, even when its `refreshedAt` is still well within TTL — otherwise the app
    /// would wait out the previous session's remaining interval before refetching. It must still *display*
    /// (instant paint), so `loadSnapshots` returns it.
    func testRelaunchLoadedSnapshotIsStaleEvenWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        // Session 1 writes a snapshot 1s ago — comfortably inside the 9_999s TTL.
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))

        // Session 2 (fresh instance = relaunch) reloads it from disk.
        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        // Display still paints the last-known value...
        XCTAssertNotNil(relaunched.loadSnapshots(keys: ["alpha"])["alpha"])
        // ...but the refresh gate treats it as stale, forcing a refresh on the first post-launch pass.
        XCTAssertNil(relaunched.snapshot(key: "alpha"))
    }

    /// Acceptance criterion 2: a snapshot written *this* session still short-circuits a redundant refresh
    /// within that session (no refresh storm) — the gate is "written this session AND within TTL", not
    /// "written this session" alone.
    func testSnapshotWrittenThisSessionStaysFreshWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        XCTAssertEqual(cache.snapshot(key: "alpha")?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// A snapshot written this session still expires once it ages past TTL, so the periodic loop resumes
    /// refetching on the normal cadence (the session-write flag widens freshness on launch, it doesn't
    /// pin a snapshot fresh forever).
    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(key: "alpha"))
    }
}
