import Foundation
import Observation

/// One-time onboarding state. Today that's a single bit: whether the dashboard should still show the
/// first-run Customize hint card. `FirstRunSeeder` marks it pending when it seeds a fresh install's
/// provider set (existing installs are never seeded, so they never see the card); it clears when the
/// user dismisses the card, visits Customize, or leaves the welcome screen with nothing on.
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
