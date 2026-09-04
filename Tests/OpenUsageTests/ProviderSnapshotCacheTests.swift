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
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
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
        XCTAssertEqual(
            relaunched.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )
        XCTAssertNil(relaunched.snapshot(providerID: "alpha"))
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
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }
}
