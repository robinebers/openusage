import Foundation

struct TelemetryConfigSnapshot: Sendable {
    struct ProviderAccounts: Sendable {
        let kind: ProviderKind
        var direct = 0
        var cliProxyAPI = 0
    }

    let providers: [ProviderAccounts]
    let enabledMetricIDs: [String]

    init(accounts: [Account], enabledMetricIDs: [String]) {
        var providers: [ProviderAccounts] = []
        for account in accounts {
            let index = providers.firstIndex { $0.kind == account.kind } ?? providers.endIndex
            if index == providers.endIndex { providers.append(ProviderAccounts(kind: account.kind)) }
            if account.hub == nil {
                providers[index].direct += 1
            } else {
                providers[index].cliProxyAPI += 1
            }
        }
        self.providers = providers
        self.enabledMetricIDs = enabledMetricIDs
    }
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
    private static let providerAccountsDayKey = "providerAccountsDay"

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

    func tick() {
        let today = Self.dayString(now())
        let sendActive = defaults.string(forKey: Self.activeDayKey) != today
        let sendProviderAccounts = isEnabled && defaults.string(forKey: Self.providerAccountsDayKey) != today
        guard sendActive || sendProviderAccounts else { return }
        let config = snapshot()

        if sendActive {
            defaults.set(today, forKey: Self.activeDayKey)
            sink.capture("app_daily_active", [
                "install_id": installID,
                "app_version": AppInfo.version,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "enabled_providers": config.providers.map(\.kind.rawValue),
                "enabled_metric_ids": config.enabledMetricIDs
            ])
        }
        if sendProviderAccounts {
            defaults.set(today, forKey: Self.providerAccountsDayKey)
            let providers: [[String: Any]] = config.providers.map {
                [
                    "provider_id": $0.kind.rawValue,
                    "direct_count": $0.direct,
                    "cliproxyapi_count": $0.cliProxyAPI
                ]
            }
            sink.capture("provider_accounts_daily", ["install_id": installID, "providers": providers])
        }
        sink.flush()
    }

    func flush() {
        sink.flush()
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
