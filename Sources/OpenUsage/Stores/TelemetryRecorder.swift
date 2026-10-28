import Foundation

struct TelemetryConfigSnapshot: Sendable {
    let enabledProviders: [String]
    let enabledMetricIDs: [String]
    let pinnedMetricIDs: [String]
}

struct ProviderDailyCounter: Codable, Sendable, Equatable {
    var day: String
    var success = 0
    var failure = 0
    var manual = 0
}

@MainActor
final class TelemetryRecorder {
    private let sink: TelemetrySink
    private let defaults: UserDefaults
    private let snapshot: @MainActor () -> TelemetryConfigSnapshot
    private let now: () -> Date

    private static let installIDKey = "installID"
    private static let enabledKey = "enabled"
    private static let activeDayKey = "activeDay"
    private static let providerDaysKey = "providerDays"

    static var suite: UserDefaults {
        UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "com.openusage.app") + ".telemetry") ?? .standard
    }

    init(
        sink: TelemetrySink,
        defaults: UserDefaults,
        snapshot: @escaping @MainActor () -> TelemetryConfigSnapshot,
        now: @escaping () -> Date = Date.init
    ) {
        self.sink = sink
        self.defaults = defaults
        self.snapshot = snapshot
        self.now = now
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey, default: true) }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        defaults.set(enabled, forKey: Self.enabledKey)
        AppLog.info(.config, "optional analytics \(enabled ? "enabled" : "disabled") by user")
    }

    var installID: String {
        if let existing = defaults.string(forKey: Self.installIDKey) { return existing }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.installIDKey)
        return minted
    }

    func providerCounters() -> [String: ProviderDailyCounter] {
        guard let data = defaults.data(forKey: Self.providerDaysKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderDailyCounter].self, from: data)) ?? [:]
    }

    func tick() {
        let today = Self.dayString(now())
        if isEnabled {
            flushStaleCounters(today: today)
        }
        if defaults.string(forKey: Self.activeDayKey) != today {
            defaults.set(today, forKey: Self.activeDayKey)
            emitDailyActive()
        }
    }

    func record(providerID: String, result: WidgetDataStore.RefreshOutcome, manual: Bool) {
        guard isEnabled, result == .refreshed || result == .failed else { return }

        let today = Self.dayString(now())
        var counters = providerCounters()
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
        setProviderCounters(counters)
    }

    func flush() {
        sink.flush()
    }

    private func flushStaleCounters(today: String) {
        var counters = providerCounters()
        var changed = false
        for (providerID, counter) in counters where counter.day != today {
            emitProviderRollup(providerID: providerID, counter: counter)
            counters[providerID] = nil
            changed = true
        }
        if changed { setProviderCounters(counters) }
    }

    private func setProviderCounters(_ counters: [String: ProviderDailyCounter]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            AppLog.warn(.config, "failed to persist telemetry counters")
            return
        }
        defaults.set(data, forKey: Self.providerDaysKey)
    }

    private func emitDailyActive() {
        let config = snapshot()
        sink.capture("app_daily_active", [
            "install_id": installID,
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

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
