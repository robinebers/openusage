import Foundation
import Observation

/// One-time onboarding state. Today that's a single bit: whether the dashboard should still show the
/// first-run Customize hint card. The welcome screen marks it pending when the user connects providers
/// (existing installs never see the welcome screen, so they never see the card); it clears when the
/// user dismisses the card or visits Customize.
@MainActor
@Observable
final class OnboardingStore {
    private static let customizeHintPendingKey = "openusage.onboarding.customizeHintPending"

    private(set) var isCustomizeHintPending: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCustomizeHintPending = defaults.bool(forKey: Self.customizeHintPendingKey)
    }

    func markCustomizeHintPending() {
        guard !isCustomizeHintPending else { return }
        isCustomizeHintPending = true
        defaults.set(true, forKey: Self.customizeHintPendingKey)
    }

    func dismissCustomizeHint() {
        guard isCustomizeHintPending else { return }
        isCustomizeHintPending = false
        defaults.set(false, forKey: Self.customizeHintPendingKey)
    }
}
