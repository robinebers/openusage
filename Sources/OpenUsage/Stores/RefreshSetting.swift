import Foundation

/// Legacy fallback refresh cadence for providers without an explicit policy.
enum RefreshSetting {
    static let defaultMinutes = 5
    static let interval = TimeInterval(defaultMinutes * 60)
}

/// Internal refresh policy for provider-aware scheduling. These are product defaults, not a user-facing
/// setting: the app stays simple while provider-specific limits remain easy to tune in code.
enum ProviderRefreshPolicy {
    static let codexBaseInterval: TimeInterval = 60
    static let claudeBaseInterval: TimeInterval = 180
    static let defaultBaseInterval = RefreshSetting.interval
    static let maxFailureBackoff: TimeInterval = 15 * 60

    static func baseInterval(for providerID: String) -> TimeInterval {
        switch providerID {
        case "codex":
            codexBaseInterval
        case "claude":
            claudeBaseInterval
        default:
            defaultBaseInterval
        }
    }

    static func failureBackoff(
        consecutiveFailures: Int,
        baseInterval: TimeInterval
    ) -> TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        let step: TimeInterval = switch consecutiveFailures {
        case 1:
            2 * 60
        case 2:
            5 * 60
        case 3:
            10 * 60
        default:
            maxFailureBackoff
        }
        return min(maxFailureBackoff, max(baseInterval, step))
    }

    static func stalenessThreshold(effectiveInterval: TimeInterval) -> TimeInterval {
        effectiveInterval * 2
    }
}
