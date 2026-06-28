import AppKit
import Observation

/// Single source of truth for the popover's transparency: the persisted "Increase Transparency"
/// preference, the ephemeral secret-code easter-egg state, and the live macOS accessibility flags that
/// both the proper toggle and the egg must yield to. Both SwiftUI (via `surfaceTreatment`) and the AppKit panel
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
    /// "Drunk Mode" — escalates the party into the woozy, barely-readable state. Only meaningful while
    /// `secretCodeActive`; cleared whenever the egg turns off.
    var drunkMode = false

    /// Live system accessibility flags. Read from `NSWorkspace` and refreshed on the change notification.
    private(set) var reduceTransparency: Bool
    private(set) var increaseContrast: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessibilityObservation: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) {
        self.defaults = defaults
        self.increaseTransparency = defaults.bool(forKey: Self.key)
        // The flags default to the live `NSWorkspace` values (production) but are injectable so tests can
        // pin them and exercise the accessibility clamp deterministically, independent of the test host.
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        startObservingAccessibility()
    }

    deinit { accessibilityObservation?.cancel() }

    /// Toggled by `TooMuchTransparencyKeyReader` when the full code is entered — so a second entry turns
    /// the egg off. Exiting drops back to the base state (Normal / Increase Transparency): the persisted
    /// `increaseTransparency` is preserved untouched (its Settings toggle is disabled while the egg runs),
    /// so the resolver returns to whichever base the user was in before.
    func toggleSecretCode() {
        setSecretCode(!secretCodeActive)
    }

    /// The Settings "Party Mode" toggle (shown only while the egg is active). Reading mirrors the egg
    /// state; setting it `false` exits the egg entirely — the only way *in* is the secret code, so the
    /// toggle is never rendered while off and `set(true)` can't be reached from the UI. Turning it off
    /// from "Party Mode + Drunk Mode" also clears Drunk Mode (you can't be drunk without the party), so
    /// both rows disappear together.
    var partyModeActive: Bool {
        get { secretCodeActive }
        set { setSecretCode(newValue) }
    }

    /// Single point that flips the egg, so the cheat code and the Party Mode toggle share one exit path:
    /// leaving the egg always clears Drunk Mode (state 4 → base, never a dangling drunk-without-party).
    private func setSecretCode(_ active: Bool) {
        guard active != secretCodeActive else { return }
        secretCodeActive = active
        if !active { drunkMode = false }
        AppLog.info(.statusItem, "Too-much-transparency egg \(active ? "enabled" : "disabled")")
    }

    /// The resolved level both the panel and the SwiftUI surface render.
    var effectiveStyle: PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increaseTransparency,
            secretCodeActive: secretCodeActive,
            drunkMode: drunkMode,
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

    /// True when the egg is active but a system accessibility setting (Reduce Transparency / Increase
    /// Contrast) is clamping the panel back to opaque — so Settings can explain why the party looks
    /// normal rather than leaving the user puzzled that the code "did nothing".
    var partyPaused: Bool {
        secretCodeActive && (reduceTransparency || increaseContrast)
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
