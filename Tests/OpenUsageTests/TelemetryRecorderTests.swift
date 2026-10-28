import XCTest
@testable import OpenUsage

/// Covers the daily-rollup/dedup contract of `TelemetryRecorder`: the 5-minute refresh timer produces
/// ~1,440 outcomes/user/day, so the recorder must collapse the real fetches among them into at most
/// one event per provider per day (and one `app_daily_active` per day) and keep the daily ping when
/// optional analytics are off.
@MainActor
final class TelemetryRecorderTests: XCTestCase {
    private typealias FakeSink = RecordingTelemetrySink

    private let snapshot = TelemetryConfigSnapshot(
        enabledProviders: ["claude", "codex"],
        enabledMetricIDs: ["claude.session", "codex.weekly"],
        pinnedMetricIDs: ["claude.session"]
    )

    func testRollOverEmitsCompleteDailyCounts() {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })

        recorder.record(providerID: "claude", result: .refreshed, manual: false)
        recorder.record(providerID: "claude", result: .refreshed, manual: true)
        recorder.record(providerID: "claude", result: .failed, manual: false)
        recorder.record(providerID: "claude", result: .failed, manual: false)
        recorder.record(providerID: "claude", result: .failed, manual: false)

        // Same day → nothing emitted yet (it's still accumulating).
        XCTAssertTrue(sink.events(named: "provider_refresh_daily").isEmpty)

        // New day → the first record rolls day 25's complete totals into one event.
        clock = day(26)
        recorder.record(providerID: "claude", result: .refreshed, manual: false)

        let rollups = sink.events(named: "provider_refresh_daily")
        XCTAssertEqual(rollups.count, 1)
        let props = rollups[0]
        XCTAssertEqual(props["provider_id"] as? String, "claude")
        XCTAssertEqual(props["success_count"] as? Int, 2)
        XCTAssertEqual(props["failure_count"] as? Int, 3)
        XCTAssertEqual(props["manual_refresh_count"] as? Int, 1)
        XCTAssertEqual(props.keys.sorted(), ["failure_count", "manual_refresh_count", "provider_id", "success_count"])
    }

    func testDailyActiveEmitsOncePerDayRegardlessOfAnalyticsOptOut() {
        for analyticsEnabled in [true, false] {
            let sink = FakeSink()
            let defaults = isolatedDefaults()
            var clock = day(25)
            let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })

            if !analyticsEnabled {
                recorder.setEnabled(false)
                XCTAssertFalse(recorder.isEnabled, "optional-analytics opt-out must persist")
            }

            recorder.tick()
            recorder.tick()

            let active = sink.events(named: "app_daily_active")
            XCTAssertEqual(active.count, 1)
            XCTAssertEqual(active[0]["install_id"] as? String, recorder.installID)
            XCTAssertEqual(active[0]["enabled_providers"] as? [String], ["claude", "codex"])
            XCTAssertEqual(active[0]["pinned_metric_ids"] as? [String], ["claude.session"])
            XCTAssertNil(active[0]["expanded_metric_ids"])
            XCTAssertNil(active[0]["menu_bar_style"])

            clock = day(26)
            recorder.tick()
            XCTAssertEqual(sink.events(named: "app_daily_active").count, 2)
        }
    }

    func testTickFlushesStalePriorDayCounterEvenWithoutNewOutcomes() {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })

        recorder.record(providerID: "grok", result: .refreshed, manual: false)

        // A new day with no further grok outcomes: the tick sweep must still emit day 25's rollup.
        clock = day(26)
        recorder.tick()

        let rollups = sink.events(named: "provider_refresh_daily")
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0]["provider_id"] as? String, "grok")
        XCTAssertEqual(rollups[0]["success_count"] as? Int, 1)
    }

    func testAnalyticsOffDoesNotEmitProviderRefreshEvents() {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })

        recorder.setEnabled(false)
        recorder.tick()
        recorder.record(providerID: "claude", result: .refreshed, manual: false)
        recorder.record(providerID: "claude", result: .failed, manual: false)
        clock = day(26)
        recorder.record(providerID: "claude", result: .failed, manual: false)
        recorder.tick()

        XCTAssertTrue(
            sink.events(named: "provider_refresh_daily").isEmpty,
            "provider rollups must not emit while analytics are off"
        )
        XCTAssertEqual(
            sink.events.map(\.name).filter { $0 != "app_daily_active" },
            [],
            "the recorder must not emit optional analytics while disabled"
        )
        XCTAssertFalse(recorder.isEnabled, "optional-analytics opt-out must persist")
    }

    func testExistingAnalyticsOptOutIsNotFlippedOn() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: "enabled")
        let sink = FakeSink()
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { self.day(25) })
        XCTAssertFalse(recorder.isEnabled, "stored analytics-off must survive a new recorder")
        recorder.tick()
        XCTAssertEqual(sink.events(named: "app_daily_active").count, 1)
        XCTAssertTrue(sink.events(named: "provider_refresh_daily").isEmpty)
        XCTAssertFalse(recorder.isEnabled)
    }

    func testKindScopedIDsNameProvidersNotAccounts() {
        XCTAssertEqual(Account.kindScopedID("claude@1a2b3c4d.session"), "claude.session")
        XCTAssertEqual(Account.kindScopedID("claude@1a2b3c4d"), "claude")
        XCTAssertEqual(Account.kindScopedID("claude.session"), "claude.session")
    }

    func testInstallIDIsStableAcrossRecorders() {
        let defaults = isolatedDefaults()
        let first = TelemetryRecorder(sink: FakeSink(), defaults: defaults, snapshot: { self.snapshot }).installID
        let second = TelemetryRecorder(sink: FakeSink(), defaults: defaults, snapshot: { self.snapshot }).installID
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    // MARK: - Helpers

    /// Local noon on 2026-06-`d`, matching the recorder's local-calendar day boundary.
    private func day(_ d: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

}
