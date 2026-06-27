import XCTest
@testable import OpenUsage

/// Covers the daily-rollup/dedup contract of `TelemetryRecorder`: the 5-minute refresh timer produces
/// ~1,440 outcomes/user/day, so the recorder must collapse them into at most one event per provider
/// per day (and one `app_daily_active` per day), drop cache/skip/backoff noise, classify errors, and
/// stop entirely when the user opts out.
@MainActor
final class TelemetryRecorderTests: XCTestCase {
    /// Records captured events without touching PostHog.
    private final class FakeSink: TelemetrySink {
        var events: [(name: String, properties: [String: Any])] = []
        var enabledCalls: [Bool] = []
        var flushCount = 0
        func capture(_ event: String, _ properties: [String: Any]) { events.append((event, properties)) }
        func setEnabled(_ enabled: Bool) { enabledCalls.append(enabled) }
        func flush() { flushCount += 1 }
        func events(named name: String) -> [[String: Any]] {
            events.filter { $0.name == name }.map(\.properties)
        }
    }

    private let snapshot = TelemetryConfigSnapshot(
        enabledProviders: ["claude", "codex"],
        enabledMetricIDs: ["claude.session", "codex.weekly"],
        pinnedMetricIDs: ["claude.session"],
        expandedMetricIDs: ["codex.weekly"],
        menuBarStyle: "text"
    )

    func testOnlyRefreshedAndFailedCount_andRollOverEmitsCompleteDailyCounts() {
        let sink = FakeSink()
        let store = makeStore("rollover")
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, store: store, snapshot: { self.snapshot }, now: { clock })

        // Day 25: real fetches plus timer noise that must be ignored.
        recorder.record(providerID: "claude", outcome: .refreshed, category: nil, manual: false)
        recorder.record(providerID: "claude", outcome: .refreshed, category: nil, manual: true)
        recorder.record(providerID: "claude", outcome: .failed, category: .network, manual: false)
        recorder.record(providerID: "claude", outcome: .failed, category: .notLoggedIn, manual: false)
        recorder.record(providerID: "claude", outcome: .failed, category: .notAvailable, manual: false)
        recorder.record(providerID: "claude", outcome: .cacheHit, category: nil, manual: false)
        recorder.record(providerID: "claude", outcome: .skipped, category: nil, manual: false)
        recorder.record(providerID: "claude", outcome: .backedOff, category: nil, manual: false)

        // Same day → nothing emitted yet (it's still accumulating).
        XCTAssertTrue(sink.events(named: "provider_refresh_daily").isEmpty)

        // New day → the first record rolls day 25's complete totals into one event.
        clock = day(26)
        recorder.record(providerID: "claude", outcome: .refreshed, category: nil, manual: false)

        let rollups = sink.events(named: "provider_refresh_daily")
        XCTAssertEqual(rollups.count, 1)
        let props = rollups[0]
        XCTAssertEqual(props["provider_id"] as? String, "claude")
        XCTAssertEqual(props["success_count"] as? Int, 2)
        XCTAssertEqual(props["failure_count"] as? Int, 3)
        XCTAssertEqual(props["manual_refresh_count"] as? Int, 1)
        XCTAssertEqual(
            props["error_categories"] as? [String: Int],
            ["network": 1, "not_available": 1, "not_logged_in": 1]
        )
        XCTAssertEqual(props["network_failure_count"] as? Int, 1)
        XCTAssertEqual(props["not_logged_in_failure_count"] as? Int, 1)
        XCTAssertEqual(props["not_available_failure_count"] as? Int, 1)
        XCTAssertEqual(props["auth_expired_failure_count"] as? Int, 0)
        XCTAssertEqual(props["expected_failure_count"] as? Int, 2)
        XCTAssertEqual(props["unexpected_failure_count"] as? Int, 1)
    }

    func testTickEmitsDailyActiveOncePerDayWithConfigSnapshot() {
        let sink = FakeSink()
        let store = makeStore("daily-active")
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, store: store, snapshot: { self.snapshot }, now: { clock })

        recorder.tick()
        recorder.tick() // same day → must not emit twice

        let active = sink.events(named: "app_daily_active")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0]["install_id"] as? String, store.installID)
        XCTAssertEqual(active[0]["enabled_providers"] as? [String], ["claude", "codex"])
        XCTAssertEqual(active[0]["pinned_metric_ids"] as? [String], ["claude.session"])
        XCTAssertEqual(active[0]["expanded_metric_ids"] as? [String], ["codex.weekly"])
        XCTAssertEqual(active[0]["menu_bar_style"] as? String, "text")

        clock = day(26)
        recorder.tick() // new day → emit again
        XCTAssertEqual(sink.events(named: "app_daily_active").count, 2)
    }

    func testTickFlushesStalePriorDayCounterEvenWithoutNewOutcomes() {
        let sink = FakeSink()
        let store = makeStore("sweep")
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, store: store, snapshot: { self.snapshot }, now: { clock })

        recorder.record(providerID: "grok", outcome: .refreshed, category: nil, manual: false)

        // A new day with no further grok outcomes: the tick sweep must still emit day 25's rollup.
        clock = day(26)
        recorder.tick()

        let rollups = sink.events(named: "provider_refresh_daily")
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0]["provider_id"] as? String, "grok")
        XCTAssertEqual(rollups[0]["success_count"] as? Int, 1)
    }

    func testOptingOutStopsAllEmissionAndPersists() {
        let sink = FakeSink()
        let store = makeStore("opt-out")
        var clock = day(25)
        let recorder = TelemetryRecorder(sink: sink, store: store, snapshot: { self.snapshot }, now: { clock })

        recorder.setEnabled(false)
        XCTAssertEqual(sink.enabledCalls, [false])

        recorder.tick()
        recorder.record(providerID: "claude", outcome: .refreshed, category: nil, manual: false)
        clock = day(26)
        recorder.record(providerID: "claude", outcome: .failed, category: .network, manual: false)
        recorder.tick()

        XCTAssertTrue(sink.events.isEmpty, "no events should be captured while opted out")
        XCTAssertFalse(store.enabled, "opt-out must persist")
    }

    func testInstallIDIsStableAcrossStoreInstances() {
        let defaults = makeDefaults("install-id")
        let first = TelemetryStore(defaults: defaults).installID
        let second = TelemetryStore(defaults: defaults).installID
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

    private func makeStore(_ name: String) -> TelemetryStore {
        TelemetryStore(defaults: makeDefaults(name))
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Telemetry.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
