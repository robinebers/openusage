import XCTest
@testable import OpenUsage

/// Keeping a provider's bars on screen while it cannot answer. Claude's usage endpoint rate-limits
/// and a limited card reports no meters at all, which used to blank every bar on it.
@MainActor
final class LastKnownMeterTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(_ name: String = "LastKnownMeter") -> (LastKnownMeterStore, UserDefaults) {
        let suite = "\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (LastKnownMeterStore(defaults: defaults, now: { self.clock }), defaults)
    }

    private func bounded(used: Double, limit: Double? = 100, hasData: Bool = true) -> WidgetData {
        var data = WidgetData(title: "Weekly", icon: .providerMark("claude"),
                              kind: .percent, used: used, limit: limit)
        data.hasData = hasData
        return data
    }

    func testRestoresTheLastReadingWhenTheProviderCannotAnswer() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly")

        let restored = store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly")

        XCTAssertEqual(restored?.used, 59)
        XCTAssertEqual(restored?.limit, 100)
        XCTAssertTrue(restored?.hasData == true)
        XCTAssertTrue(restored?.isOutdated == true)
    }

    func testRestoredReadingCarriesNoResetDate() {
        // A stored reset date would age into a countdown running backwards.
        let (store, _) = store()
        var live = bounded(used: 59)
        live.resetsAt = clock.addingTimeInterval(3600)
        store.record(live, for: "claude.weekly")

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly")?.resetsAt)
    }

    func testNothingToRestoreForAnUnknownMetric() {
        let (store, _) = store()

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.session"))
    }

    func testUnboundedAndNoDataReadingsAreNeverRecorded() {
        let (store, _) = store()
        store.record(bounded(used: 12, limit: nil), for: "claude.today")
        store.record(bounded(used: 12, hasData: false), for: "claude.weekly")

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.today"))
        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly"))
    }

    func testAReadingSurvivesARelaunch() {
        // The provider's own last-good copy is in memory; this is the part that outlives a restart.
        let suite = "LastKnownMeter.Relaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        LastKnownMeterStore(defaults: defaults, now: { self.clock })
            .record(bounded(used: 59), for: "claude.weekly")

        let next = LastKnownMeterStore(defaults: defaults, now: { self.clock })

        XCTAssertEqual(next.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly")?.used, 59)
    }

    func testAStaleReadingStopsStandingIn() {
        // Past a week a percentage of a five-hour window is fiction, so the row goes back to No data.
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly")
        clock = clock.addingTimeInterval(LastKnownMeterStore.maximumAge + 1)

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly"))
    }

    func testClearForgetsEverything() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly")

        store.clear()

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly"))
    }

    func testAFreshReadingReplacesTheStoredOne() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly")
        store.record(bounded(used: 61), for: "claude.weekly")

        XCTAssertEqual(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly")?.used, 61)
    }

    func testLiveReadingsAreNeverMarkedOutdated() {
        XCTAssertFalse(bounded(used: 59).isOutdated)
    }
}
