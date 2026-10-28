import Foundation
import Observation

/// User preferences for quota pace notifications: the three per-milestone triggers (no master switch —
/// turn all three off to silence). All default OFF; the app requests notification authorization the
/// first time a trigger is turned on, so a fresh install stays quiet until the user opts in.
///
/// Persisted in `UserDefaults` (each key independently, with an unset key defaulting to `false`).
/// `@Observable` lets the Settings toggles and `WidgetDataStore` evaluation read live values.
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults

    private static let underTenKey = "openusage.notifications.underTenPercent"
    private static let healthyToCloseKey = "openusage.notifications.healthyToClose"
    private static let closeToRunningOutKey = "openusage.notifications.closeToRunningOut"

    /// Alert the first time a metric drops under 10% remaining for the period.
    var underTenPercent: Bool {
        didSet { defaults.set(underTenPercent, forKey: Self.underTenKey) }
    }

    /// Alert when pace worsens from healthy (blue) to close-to-limit (orange).
    var healthyToClose: Bool {
        didSet { defaults.set(healthyToClose, forKey: Self.healthyToCloseKey) }
    }

    /// Alert when pace worsens from close-to-limit (orange) to running-out (red).
    var closeToRunningOut: Bool {
        didSet { defaults.set(closeToRunningOut, forKey: Self.closeToRunningOutKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.underTenPercent = defaults.bool(forKey: Self.underTenKey, default: false)
        self.healthyToClose = defaults.bool(forKey: Self.healthyToCloseKey, default: false)
        self.closeToRunningOut = defaults.bool(forKey: Self.closeToRunningOutKey, default: false)
    }

    /// Whether the trigger for `milestone` is on.
    func isOn(_ milestone: PaceMilestone) -> Bool {
        switch milestone {
        case .underTenPercent: return underTenPercent
        case .healthyToClose: return healthyToClose
        case .closeToRunningOut: return closeToRunningOut
        }
    }
}
