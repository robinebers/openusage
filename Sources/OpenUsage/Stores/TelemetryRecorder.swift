import Foundation

/// The once-a-day configuration snapshot that rides on `app_daily_active` (answers "which providers /
/// metrics are shown" and "which are pinned to the menu bar"). All values are stable IDs.
struct TelemetryConfigSnapshot: Sendable {
    let enabledProviders: [String]
    let enabledMetricIDs: [String]
    let pinnedMetricIDs: [String]
}

/// Turns raw refresh outcomes into the two daily-rollup events, enforcing "at most one event per day"
/// without flooding the pipeline from the 5-minute refresh timer (~1,440 outcomes/user/day).
///
/// - `app_daily_active`: emitted once per local day (DAU + the config snapshot), driven by `tick()`.
///   This ping is always sent — the Settings toggle does not gate it.
/// - `provider_refresh_daily`: one per provider per day, accumulated in the persisted store and emitted
///   when the day rolls over (so counts are complete and survive app restarts within a day). Gated on
///   the optional-analytics toggle. Crash reporting is handled separately and always remains enabled.
@MainActor
final class TelemetryRecorder {
    private let sink: TelemetrySink
    private let store: TelemetryStore
    private let snapshot: @MainActor () -> TelemetryConfigSnapshot
    private let now: () -> Date

    init(
        sink: TelemetrySink,
        store: TelemetryStore,
        snapshot: @escaping @MainActor () -> TelemetryConfigSnapshot,
        now: @escaping () -> Date = Date.init
    ) {
        self.sink = sink
        self.store = store
        self.snapshot = snapshot
        self.now = now
    }

    /// Whether optional provider rollups are on. Independent of the mandatory daily ping and crash
    /// reports.
    var isEnabled: Bool { store.enabled }

    /// Toggle optional provider analytics without stopping daily activity or crash reporting.
    func setEnabled(_ enabled: Bool) {
        guard store.enabled != enabled else { return }
        store.enabled = enabled
        AppLog.info(.config, "optional analytics \(enabled ? "enabled" : "disabled") by user")
    }

    /// Run on every refresh pass (launch + each interval): flush any provider counters left over from a
    /// previous day (only while optional analytics are on), then emit `app_daily_active` once per local
    /// day regardless of the analytics toggle.
    func tick() {
        let today = Self.dayString(now())
        if store.enabled {
            flushStaleCounters(today: today)
        }
        if store.activeDay != today {
            store.activeDay = today
            emitDailyActive()
        }
    }

    /// Record one real provider fetch (`.refreshed` or `.failed`). Skipped while optional analytics are off.
    func record(providerID: String, result: WidgetDataStore.RefreshOutcome, manual: Bool) {
        guard store.enabled, result == .refreshed || result == .failed else { return }

        let today = Self.dayString(now())
        var counters = store.providerCounters()
        // Roll a stale prior-day counter over to its own event before accumulating today's.
        if let existing = counters[providerID], existing.day != today {
            emitProviderRollup(providerID: providerID, counter: existing)
            counters[providerID] = nil
        }
        var counter = counters[providerID] ?? ProviderDailyCounter(day: today)
        if result == .refreshed {
            counter.success += 1
        } else {
            counter.failure += 1
        }
        if manual { counter.manual += 1 }
        counters[providerID] = counter
        store.setProviderCounters(counters)
    }

    func flush() {
        sink.flush()
    }

    // MARK: - Internals

    /// Emit (and clear) every provider counter that belongs to a day other than `today`.
    private func flushStaleCounters(today: String) {
        var counters = store.providerCounters()
        var changed = false
        for (providerID, counter) in counters where counter.day != today {
            emitProviderRollup(providerID: providerID, counter: counter)
            counters[providerID] = nil
            changed = true
        }
        if changed { store.setProviderCounters(counters) }
    }

    private func emitDailyActive() {
        let config = snapshot()
        sink.capture("app_daily_active", [
            "install_id": store.installID,
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "enabled_providers": config.enabledProviders,
            "enabled_metric_ids": config.enabledMetricIDs,
            "pinned_metric_ids": config.pinnedMetricIDs
        ])
        sink.flush()
    }

    private func emitProviderRollup(providerID: String, counter: ProviderDailyCounter) {
        sink.capture("provider_refresh_daily", [
            "provider_id": providerID,
            "success_count": counter.success,
            "failure_count": counter.failure,
            "manual_refresh_count": counter.manual
        ])
        sink.flush()
    }

    /// Local-calendar `yyyy-MM-dd`. Local (not UTC) so "every day" matches the user's perception; the
    /// calendar is injectable for tests.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
