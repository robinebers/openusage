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
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: nil)

        let restored = store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil)

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
        store.record(live, for: "claude.weekly", capturedAt: clock, identityKey: nil)

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil)?.resetsAt)
    }

    func testNothingToRestoreForAnUnknownMetric() {
        let (store, _) = store()

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.session", identityKey: nil))
    }

    func testUnboundedAndNoDataReadingsAreNeverRecorded() {
        let (store, _) = store()
        store.record(bounded(used: 12, limit: nil), for: "claude.today", capturedAt: clock, identityKey: nil)
        store.record(bounded(used: 12, hasData: false), for: "claude.weekly", capturedAt: clock, identityKey: nil)

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.today", identityKey: nil))
        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil))
    }

    func testAReadingSurvivesARelaunch() {
        // The provider's own last-good copy is in memory; this is the part that outlives a restart.
        let suite = "LastKnownMeter.Relaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        LastKnownMeterStore(defaults: defaults, now: { self.clock })
            .record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: nil)

        let next = LastKnownMeterStore(defaults: defaults, now: { self.clock })

        XCTAssertEqual(next.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil)?.used, 59)
    }

    func testAStaleReadingStopsStandingIn() {
        // Past a week a percentage of a five-hour window is fiction, so the row goes back to No data.
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: nil)
        clock = clock.addingTimeInterval(LastKnownMeterStore.maximumAge + 1)

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil))
    }

    func testClearForgetsEverything() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: nil)

        store.clear()

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil))
    }

    func testAFreshReadingReplacesTheStoredOne() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: nil)
        store.record(bounded(used: 61), for: "claude.weekly", capturedAt: clock, identityKey: nil)

        XCTAssertEqual(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil)?.used, 61)
    }

    func testLiveReadingsAreNeverMarkedOutdated() {
        XCTAssertFalse(bounded(used: 59).isOutdated)
    }

    // MARK: - Ownership, age, and timing

    func testAnotherAccountsReadingNeverStandsIn() {
        let (store, _) = store()
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock, identityKey: "acct-A")
        let sample = bounded(used: 0, hasData: false)

        XCTAssertNil(store.restore(onto: sample, for: "claude.weekly", identityKey: "acct-B"))
        XCTAssertEqual(store.restore(onto: sample, for: "claude.weekly", identityKey: "acct-A")?.used, 59)
        XCTAssertEqual(store.restore(onto: sample, for: "claude.weekly", identityKey: nil)?.used, 59,
                       "An unresolved account can't verify either way, as with the snapshot cache")
    }

    func testAgeCountsFromTheMeasurementNotTheLastRecord() {
        // Recording an old snapshot again (every render does) must not renew it.
        let (store, _) = store()
        let measured = clock.addingTimeInterval(-(LastKnownMeterStore.maximumAge + 60))
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: measured, identityKey: nil)
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: measured, identityKey: nil)

        XCTAssertNil(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil))
    }

    func testAnOlderMeasurementNeverReplacesANewerOne() {
        let (store, _) = store()
        store.record(bounded(used: 61), for: "claude.weekly", capturedAt: clock, identityKey: nil)
        store.record(bounded(used: 59), for: "claude.weekly", capturedAt: clock.addingTimeInterval(-60), identityKey: nil)

        XCTAssertEqual(store.restore(onto: bounded(used: 0, hasData: false), for: "claude.weekly", identityKey: nil)?.used, 61)
    }

    func testARestoredSessionUnderOnePercentNeverReadsNotStarted() {
        // Claude reports whole percents, so an active session can read 0 with a reset date. Restored,
        // the date is gone, and without care the row would claim the window hasn't started.
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let session = WidgetDescriptor.percent(id: "claude.session", provider: provider, title: "Session",
                                               sessionStartSignal: .missingResetDate)
        var live = session.sample
        live.resetsAt = clock.addingTimeInterval(3600)
        let (store, _) = store()
        store.record(live, for: session.id, capturedAt: clock, identityKey: nil)

        let restored = store.restore(onto: session.sample, for: session.id, identityKey: nil)

        XCTAssertEqual(restored?.isFreshSessionWindow(now: clock), false)
        XCTAssertNil(restored?.boundedTrailingText(now: clock))
    }

    func testARestoredMonthlyCountClaimsNoResetCountdown() {
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let searches = WidgetDescriptor.boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                                                     limit: 1000, suffix: "searches",
                                                     periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
        var live = searches.sample
        live.used = 120
        let (store, _) = store()
        store.record(live, for: searches.id, capturedAt: clock, identityKey: nil)

        let restored = store.restore(onto: searches.sample, for: searches.id, identityKey: nil)

        XCTAssertEqual(restored?.used, 120)
        XCTAssertFalse(restored?.boundedTrailingText(now: clock)?.contains("Resets") ?? false,
                       "Got \(restored?.boundedTrailingText(now: clock) ?? "nil")")
    }
}
