import XCTest
@testable import OpenUsage

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
}
