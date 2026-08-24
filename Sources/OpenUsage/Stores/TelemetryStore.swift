import Foundation

/// Per-provider running tally for one local calendar day. Persisted so counts survive app restarts
/// within a day, then emitted as a single `provider_refresh_daily` event once the day rolls over.
struct ProviderDailyCounter: Codable, Sendable, Equatable {
    var day: String
    var success = 0
    var failure = 0
    var manual = 0
    /// Stable `ErrorCategory` raw value -> count. No messages, no PII.
    var errors: [String: Int] = [:]
}

/// Telemetry bookkeeping kept in its own `UserDefaults` suite domain (`<bundle id>.telemetry`), separate
/// from the app's standard settings domain. That isolation keeps the anonymous install id, the user's
/// optional-analytics choice, and the daily-dedup state independent of app settings — so a settings
/// change can never re-enable extra analytics the user turned off or mint a new install id (which
/// would inflate DAU / new-install counts). Daily activity and crash reports ignore that choice.
@MainActor
final class TelemetryStore {
    private let defaults: UserDefaults

    private static let installIDKey = "installID"
    private static let enabledKey = "enabled"
    private static let activeDayKey = "activeDay"
    private static let providerDaysKey = "providerDays"

    static var suiteName: String { (Bundle.main.bundleIdentifier ?? "com.openusage.app") + ".telemetry" }

    /// `defaults` is injectable for tests; production uses the dedicated suite (falling back to standard
    /// only if the suite can't be opened, which would be unusual).
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// Stable anonymous install id (random UUID), minted once on first read and reused thereafter.
    var installID: String {
        if let existing = defaults.string(forKey: Self.installIDKey) { return existing }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.installIDKey)
        return minted
    }

    /// Whether optional usage analytics are enabled (provider rollups and error categories).
    /// Defaults to `true` when the user has never chosen. Existing opt-outs stay stored here; the
    /// daily active ping and crash reports do not read this flag.
    var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey, default: true) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The last local day on which `app_daily_active` was emitted (`yyyy-MM-dd`), or nil if never.
    var activeDay: String? {
        get { defaults.string(forKey: Self.activeDayKey) }
        set { defaults.set(newValue, forKey: Self.activeDayKey) }
    }

    func providerCounters() -> [String: ProviderDailyCounter] {
        guard let data = defaults.data(forKey: Self.providerDaysKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderDailyCounter].self, from: data)) ?? [:]
    }

    func setProviderCounters(_ counters: [String: ProviderDailyCounter]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            AppLog.warn(.config, "failed to persist telemetry counters")
            return
        }
        defaults.set(data, forKey: Self.providerDaysKey)
    }
}
