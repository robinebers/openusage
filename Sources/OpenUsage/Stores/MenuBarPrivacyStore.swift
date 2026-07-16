import Foundation
import Observation

/// Single source of truth for the menu bar's screen-share privacy mode: the persisted "Hide From
/// Screen Share" preference plus the live is-the-screen-captured signal behind it.
/// `StatusItemImageUpdater` reads `concealUsage` inside its observation loop, so the strip swaps to
/// the wordmark the moment a capture starts and back when it ends; Settings binds the toggle and
/// shows a live "concealing right now" notice.
///
/// Monitoring runs only while the setting is on: a short poll (the guarantee) plus the window
/// server's watcher notifications (the fast path — private and best-effort, so never relied on
/// alone). With the setting off the store does no periodic work at all.
@MainActor
@Observable
final class MenuBarPrivacyStore {
    static let key = "hideUsageWhileScreenSharing"

    /// How often the poll re-checks the watcher flag while the setting is on. Short enough that a
    /// missed notification exposes usage for a few seconds at worst; the check itself is a single
    /// cheap window-server call.
    static let pollInterval: Duration = .seconds(3)

    /// The persisted preference (default off). Stored here rather than as a view-local `@AppStorage`
    /// so the AppKit strip renderer honors exactly the value the Settings toggle writes. Toggling it
    /// starts/stops the capture monitoring, so the off state costs nothing.
    var hideUsageWhileScreenSharing: Bool {
        didSet {
            guard hideUsageWhileScreenSharing != oldValue else { return }
            defaults.set(hideUsageWhileScreenSharing, forKey: Self.key)
            if hideUsageWhileScreenSharing {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    /// Whether a screen capture is active right now. Only maintained while the setting is on;
    /// always `false` otherwise.
    private(set) var screenIsCaptured = false

    /// True exactly when the menu bar should show the wordmark instead of usage values.
    var concealUsage: Bool { hideUsageWhileScreenSharing && screenIsCaptured }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probe: @MainActor () -> Bool
    @ObservationIgnored private let installChangeNotifications: @MainActor (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// The probe and notification installer default to the real window-server signal
    /// (`ScreenCaptureProbe`) and are injectable so tests can pin the capture state deterministically.
    init(
        defaults: UserDefaults = .standard,
        probe: @escaping @MainActor () -> Bool = ScreenCaptureProbe.isScreenCaptured,
        installChangeNotifications: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void = ScreenCaptureProbe.installChangeNotifications
    ) {
        self.defaults = defaults
        self.probe = probe
        self.installChangeNotifications = installChangeNotifications
        self.hideUsageWhileScreenSharing = defaults.bool(forKey: Self.key)
        // `didSet` doesn't fire during init; arm monitoring for a persisted-on launch directly.
        if hideUsageWhileScreenSharing {
            startMonitoring()
        }
    }

    deinit { pollTask?.cancel() }

    /// Re-reads the watcher flag and publishes a change. Called by the poll, the window-server
    /// notification hop, and monitoring start. Reads through the setting so a stale notification
    /// arriving after the toggle turned off can't re-conceal.
    func refreshCaptureState() {
        let captured = hideUsageWhileScreenSharing && probe()
        guard captured != screenIsCaptured else { return }
        screenIsCaptured = captured
        AppLog.info(.menubar, captured
            ? "Screen capture detected; menu bar shows the wordmark"
            : "Screen capture ended; menu bar shows usage again")
    }

    private func startMonitoring() {
        guard pollTask == nil else { return }
        installChangeNotifications { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCaptureState()
            }
        }
        refreshCaptureState()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refreshCaptureState()
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        if screenIsCaptured {
            screenIsCaptured = false
        }
    }
}
