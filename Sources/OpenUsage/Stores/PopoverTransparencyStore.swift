import AppKit
import Observation

/// Single source of truth for the popover's transparency: the persisted "Increase Transparency"
/// preference, the ephemeral secret-code easter-egg state, and the live macOS accessibility flags the proper
/// toggle must yield to. Both SwiftUI (via `surfaceTreatment`) and the AppKit panel
/// (`StatusItemController`, via `effectiveStyle`) read this one store, so the SwiftUI surface and the
/// window can't drift apart.
@MainActor
@Observable
final class PopoverTransparencyStore {
    static let key = "increaseTransparency"

    /// The persisted preference (default off). Stored here rather than as a view-local `@AppStorage` so
    /// the AppKit panel honors exactly the value the Settings toggle writes. The no-op guard avoids a
    /// redundant defaults write (and the firehose `UserDefaults.didChangeNotification` it would emit).
    var increaseTransparency: Bool {
        didSet {
            guard increaseTransparency != oldValue else { return }
            defaults.set(increaseTransparency, forKey: Self.key)
        }
    }

    /// Ephemeral easter-egg state. Never persisted: it clears on quit, but survives panel open/close
    /// within a run, so the only way out is re-typing the code.
    private(set) var secretCodeActive = false
    /// "Even More" — only meaningful while `secretCodeActive`. Cleared whenever the egg turns off.
    var evenMore = false

    /// Live system accessibility flags. Read from `NSWorkspace` and refreshed on the change notification.
    private(set) var reduceTransparency: Bool
    private(set) var increaseContrast: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessibilityObservation: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.increaseTransparency = defaults.bool(forKey: Self.key)
        let workspace = NSWorkspace.shared
        self.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        self.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        startObservingAccessibility()
    }

    deinit { accessibilityObservation?.cancel() }

    /// Toggled by `TooMuchTransparencyKeyReader` when the full code is entered — so a second entry turns
    /// the egg off.
    func toggleSecretCode() {
        secretCodeActive.toggle()
        if !secretCodeActive { evenMore = false }
        AppLog.info(.statusItem, "Too-much-transparency egg \(secretCodeActive ? "enabled" : "disabled")")
    }

    /// The resolved level both the panel and the SwiftUI surface render.
    var effectiveStyle: PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increaseTransparency,
            secretCodeActive: secretCodeActive,
            evenMore: evenMore,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    /// SwiftUI surface treatment derived from the resolved style.
    var surfaceTreatment: PopoverSurfaceTreatment { effectiveStyle.surfaceTreatment }

    /// True when the user turned the proper toggle on but a system accessibility setting is overriding it
    /// — so Settings can show a friendly "paused" note instead of silently doing nothing.
    var isPaused: Bool {
        increaseTransparency && (reduceTransparency || increaseContrast)
    }

    /// Accessibility display options post to `NSWorkspace`'s OWN notification center (never `.default`).
    /// The notification carries no payload, so we ignore it and re-read the flags on the main actor —
    /// which also sidesteps the non-`Sendable` `Notification` under Swift 6 strict concurrency.
    private func startObservingAccessibility() {
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        accessibilityObservation = Task { [weak self] in
            for await _ in center.notifications(named: name) {
                self?.refreshAccessibilityFlags()
            }
        }
    }

    private func refreshAccessibilityFlags() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}
