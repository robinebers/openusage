import Foundation

/// The once-a-day configuration snapshot that rides on `app_daily_active` (answers "which providers /
/// metrics are enabled" and "which are Always Visible vs On Demand"). All values are stable IDs/enums.
struct TelemetryConfigSnapshot: Sendable {
    let enabledProviders: [String]
    let enabledMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
    let menuBarStyle: String
}

/// Turns raw refresh outcomes into the two daily-rollup events, enforcing "at most one event per day"
/// without flooding the pipeline from the 5-minute refresh timer (~1,440 outcomes/user/day).
///
/// - `app_daily_active`: emitted once per local day (DAU + the config snapshot), driven by `tick()`.
/// - `provider_refresh_daily`: one per provider per day, accumulated in the persisted store and emitted
///   when the day rolls over (so counts are complete and survive app restarts within a day).
///
/// All work is skipped while telemetry is disabled, so opting out is a hard stop, not just a no-op sink.
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

    var isEnabled: Bool { store.enabled }

    /// Toggle the user's opt-out choice: persist it (in the beta-wipe-proof store) and mirror it onto
    /// the SDK. A no-op when unchanged.
    func setEnabled(_ enabled: Bool) {
        guard store.enabled != enabled else { return }
        store.enabled = enabled
        sink.setEnabled(enabled)
        AppLog.info(.config, "telemetry \(enabled ? "enabled" : "disabled") by user")
    }

    /// Run on every refresh pass (launch + each interval): flush any provider counters left over from a
    /// previous day, then emit `app_daily_active` once per local day.
    func tick() {
        guard store.enabled else { return }
        let today = Self.dayString(now())
        flushStaleCounters(today: today)
        if store.activeDay != today {
            store.activeDay = today
            emitDailyActive()
        }
    }

    /// Record one provider refresh outcome. Only `.refreshed` / `.failed` count — cache hits, skips, and
    /// backoffs are timer noise, not usage, and are dropped.
    func record(providerID: String, outcome: WidgetDataStore.RefreshOutcome, category: ErrorCategory?, manual: Bool) {
        guard store.enabled else { return }
        guard outcome == .refreshed || outcome == .failed else { return }

        let today = Self.dayString(now())
        var counters = store.providerCounters()
        // Roll a stale prior-day counter over to its own event before accumulating today's.
        if let existing = counters[providerID], existing.day != today {
            emitProviderRollup(providerID: providerID, counter: existing)
            counters[providerID] = nil
        }
        var counter = counters[providerID] ?? ProviderDailyCounter(day: today)
        switch outcome {
        case .refreshed:
            counter.success += 1
        case .failed:
            counter.failure += 1
            counter.errors[(category ?? .other).rawValue, default: 0] += 1
        default:
            break
        }
        if manual { counter.manual += 1 }
        counters[providerID] = counter
        store.setProviderCounters(counters)
    }

    func flush() {
        guard store.enabled else { return }
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
            "pinned_metric_ids": config.pinnedMetricIDs,
            "expanded_metric_ids": config.expandedMetricIDs,
            "menu_bar_style": config.menuBarStyle
        ])
        sink.flush()
    }

    private func emitProviderRollup(providerID: String, counter: ProviderDailyCounter) {
        sink.capture("provider_refresh_daily", Self.providerRollupProperties(providerID: providerID, counter: counter))
        sink.flush()
    }

    private static func providerRollupProperties(providerID: String, counter: ProviderDailyCounter) -> [String: Any] {
        var properties: [String: Any] = [
            "provider_id": providerID,
            "success_count": counter.success,
            "failure_count": counter.failure,
            "error_categories": counter.errors,
            "manual_refresh_count": counter.manual
        ]

        for category in ErrorCategory.allCases {
            properties["\(category.rawValue)_failure_count"] = counter.errors[category.rawValue] ?? 0
        }

        let expectedFailureCount = [ErrorCategory.notLoggedIn, .notAvailable].reduce(0) { total, category in
            total + (counter.errors[category.rawValue] ?? 0)
        }
        properties["expected_failure_count"] = expectedFailureCount
        properties["unexpected_failure_count"] = max(0, counter.failure - expectedFailureCount)
        return properties
    }

    /// Local-calendar `yyyy-MM-dd`. Local (not UTC) so "every day" matches the user's perception; the
    /// calendar is injectable for tests.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
