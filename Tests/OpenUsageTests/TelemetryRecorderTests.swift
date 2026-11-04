import XCTest
@testable import OpenUsage

@MainActor
final class TelemetryRecorderTests: XCTestCase {
    private typealias FakeSink = RecordingTelemetrySink

    private let snapshot = TelemetryConfigSnapshot(
        accounts: [Account(kind: .claude, label: "Claude"), Account(kind: .codex, label: "Codex")],
        enabledMetricIDs: ["claude.session", "codex.weekly"],
    )

    func testProviderAccountsEmitOncePerDayAcrossRestartsAndReflectCurrentAccounts() throws {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })
        recorder.tick()
        recorder.tick()

        let restarted = TelemetryRecorder(
            sink: sink,
            defaults: defaults,
            snapshot: { TelemetryConfigSnapshot(accounts: [], enabledMetricIDs: []) },
            now: { clock }
        )
        restarted.tick()
        XCTAssertEqual(sink.events.map(\.name), ["app_daily_active", "provider_accounts_daily"])

        clock = day(26)
        restarted.tick()
        XCTAssertEqual(sink.events.map(\.name), [
            "app_daily_active", "provider_accounts_daily", "app_daily_active", "provider_accounts_daily"
        ])
        let latest = try XCTUnwrap(sink.events(named: "provider_accounts_daily").last)
        XCTAssertEqual(latest["install_id"] as? String, recorder.installID)
        XCTAssertTrue(try XCTUnwrap(latest["providers"] as? [[String: Any]]).isEmpty)
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
            XCTAssertNil(active[0]["pinned_metric_ids"])
            XCTAssertNil(active[0]["expanded_metric_ids"])
            XCTAssertNil(active[0]["menu_bar_style"])

            clock = day(26)
            recorder.tick()
            XCTAssertEqual(sink.events(named: "app_daily_active").count, 2)
        }
    }

    func testProviderAccountsCanStartAfterTheDailyPingWithoutSendingTwice() {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { self.day(25) })
        recorder.setEnabled(false)
        recorder.tick()
        XCTAssertEqual(sink.events.map(\.name), ["app_daily_active"])
        recorder.setEnabled(true)
        recorder.tick()
        recorder.setEnabled(false)
        recorder.setEnabled(true)
        recorder.tick()
        XCTAssertEqual(sink.events.map(\.name), ["app_daily_active", "provider_accounts_daily"])
    }

    func testAnalyticsOffDoesNotEmitProviderAccountCounts() {
        let sink = FakeSink()
        let defaults = isolatedDefaults()
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, defaults: defaults, snapshot: { self.snapshot }, now: { clock })

        recorder.setEnabled(false)
        recorder.tick()
        clock = day(26)
        recorder.tick()

        XCTAssertEqual(
            sink.events.map(\.name),
            ["app_daily_active", "app_daily_active"],
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
        XCTAssertTrue(sink.events(named: "provider_accounts_daily").isEmpty)
        XCTAssertFalse(recorder.isEnabled)
    }

    func testInstallIDIsStableAcrossRecorders() {
        let defaults = isolatedDefaults()
        let first = TelemetryRecorder(sink: FakeSink(), defaults: defaults, snapshot: { self.snapshot }).installID
        let second = TelemetryRecorder(sink: FakeSink(), defaults: defaults, snapshot: { self.snapshot }).installID
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    private func day(_ d: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

}
