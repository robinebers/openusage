import XCTest
@testable import OpenUsage

/// Guards the in-memory mirror: reads must reflect writes, a second store must not drop the first, and
/// every store reaches disk (a fresh instance reads it back).
final class ProviderSnapshotCacheTests: XCTestCase {
    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: isolatedDefaults(), storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        // The second store must not drop the first, and reads come back from the mirror unchanged.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testEveryStoreReachesDisk() {
        let defaults = isolatedDefaults()
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
    }

    /// A snapshot another app version saved is shown at launch (`loadSnapshots`) but never satisfies the
    /// refresh gate, even within TTL, so an update refetches instead of showing what the old version read
    /// (#697). Once this session writes any snapshot, the old ones still don't count as fresh.
    func testSnapshotFromAnotherAppVersionIsStaleEvenWithinTTL() {
        let defaults = isolatedDefaults()
        let now = Date()
        let old = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", appVersion: "1.0.0", ttl: 9_999, now: { now })
        old.store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))
        old.store(snapshot("beta", used: 7, now: now.addingTimeInterval(-1)))

        let updated = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", appVersion: "1.0.1", ttl: 9_999, now: { now })
        XCTAssertEqual(
            updated.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )
        XCTAssertNil(updated.snapshot(providerID: "alpha"))
        updated.store(snapshot("alpha", used: 43, now: now))
        XCTAssertNotNil(updated.snapshot(providerID: "alpha"))
        XCTAssertNil(updated.snapshot(providerID: "beta"))
    }

    /// The same app version relaunched inside TTL trusts what it saved, and a snapshot from the future (a
    /// clock that moved back) is never fresh.
    func testSameVersionRelaunchTrustsItsSnapshotsWithinTTL() {
        let defaults = isolatedDefaults()
        let now = Date()
        let first = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", appVersion: "1.0.0", ttl: 300, now: { now })
        first.store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-299)))
        first.store(snapshot("beta", used: 7, now: now.addingTimeInterval(60)))

        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", appVersion: "1.0.0", ttl: 300, now: { now })
        XCTAssertNotNil(relaunched.snapshot(providerID: "alpha"))
        XCTAssertNil(relaunched.snapshot(providerID: "beta"))
    }

    /// A snapshot written this session still expires once it ages past TTL, so the periodic loop resumes
    /// refetching on the normal cadence.
    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: isolatedDefaults(), storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }
}
