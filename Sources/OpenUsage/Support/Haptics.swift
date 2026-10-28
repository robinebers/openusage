import AppKit

/// Trackpad haptics via the Force Touch Taptic Engine (`NSHapticFeedbackManager`). Silent no-op on
/// hardware without one (regular mice, older trackpads). Per the HIG these fire only in direct
/// response to a user-driven gesture — the system only delivers them while fingers are on the
/// trackpad anyway, so a drag is exactly the sanctioned moment.
///
/// Drags only — never fire a haptic from a mouse-click action. A Force Touch click is itself
/// simulated by the Taptic Engine (press pulse at mouse-down, release pulse at mouse-up), and a
/// button action runs at mouse-up, so an app pulse there lands milliseconds after the release
/// click and reads as a double vibration. The click is its own feedback.
@MainActor
enum Haptics {
    /// The "snapped into place" tap — fire when a drag actually commits a new order, never on
    /// plain drag movement.
    ///
    /// Exactly one `.levelChange` pulse per commit: pulses milliseconds apart don't fuse on hardware,
    /// `.alignment` is imperceptible, and anything stronger means private APIs.
    /// Minimum spacing between taps: rapid slot-crossings during a fast drag would otherwise
    /// run pulses together into a buzz. With the floor, every snap renders identically
    /// everywhere — reorder on the dashboard, reorder in Accounts.
    private static let minimumSnapInterval: TimeInterval = 0.12
    private static var lastSnapAt: TimeInterval = 0

    static func snap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnapAt >= minimumSnapInterval else { return }
        lastSnapAt = now

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
