import XCTest
@testable import OpenUsage

/// The cache is plain persistence: what one instance saves, a fresh instance loads back.
final class ProviderSnapshotCacheTests: XCTestCase {
    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testEverySaveReachesDisk() {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k").save([
            "alpha": snapshot("alpha", used: 10, now: now),
            "beta": snapshot("beta", used: 20, now: now),
        ])

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k").load()
        XCTAssertEqual(reloaded["alpha"]?.lines.first, .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(reloaded["beta"]?.lines.first, .progress(label: "Session", used: 20, limit: 100, format: .percent))
        XCTAssertEqual(reloaded["alpha"]?.refreshedAt, now)
    }

    /// A blob saved while the payload still carried the app version that wrote it loads as before.
    func testBlobSavedWithAnAppVersionStillLoads() throws {
        struct VersionedPayload: Encodable {
            var snapshots: [String: ProviderSnapshot]
            var appVersion: String
        }
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = VersionedPayload(snapshots: ["alpha": snapshot("alpha", used: 42, now: now)], appVersion: "1.0.0")
        defaults.set(try encoder.encode(saved), forKey: "k")

        XCTAssertEqual(
            ProviderSnapshotCache(userDefaults: defaults, storageKey: "k").load()["alpha"]?.lines.first,
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )
    }
}
