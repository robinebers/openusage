import AppKit
import Foundation

/// App-specific motion preference. It supplements macOS Reduce Motion so either choice can request
/// the same reduced-animation behavior throughout the SwiftUI tree and the AppKit panel bridge.
enum ReduceAnimationsSetting {
    static let key = "reduceAnimations"
    static let fallback = false

    static func resolve(appPreference: Bool, systemReduceMotion: Bool) -> Bool {
        appPreference || systemReduceMotion
    }

    /// Live value for imperative AppKit animation sites. SwiftUI reads the same two inputs through
    /// `@AppStorage` and `accessibilityReduceMotion` in `ReduceAnimationsModifier`.
    @MainActor
    static var isEnabled: Bool {
        resolve(
            appPreference: UserDefaults.standard.bool(forKey: key),
            systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}
