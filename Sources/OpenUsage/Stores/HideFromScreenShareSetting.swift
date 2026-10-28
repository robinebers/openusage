import Foundation
import Observation

/// The Hide From Screen Share setting and the live capture signal behind it. Capture is watched only
/// while the setting is on: a short poll is the guarantee, and the window server's change
/// notifications, private and best-effort, only make the swap faster.
@MainActor
@Observable
final class HideFromScreenShareSetting {
    static let key = "hideUsageWhileScreenSharing"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.key)
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private(set) var isConcealing = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isScreenCaptured: @MainActor () -> Bool
    @ObservationIgnored private let installChangeNotifications: @MainActor (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        isScreenCaptured: @escaping @MainActor () -> Bool = ScreenCaptureProbe.isScreenCaptured,
        installChangeNotifications: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void = ScreenCaptureProbe.installChangeNotifications
    ) {
        self.defaults = defaults
        self.isScreenCaptured = isScreenCaptured
        self.installChangeNotifications = installChangeNotifications
        isEnabled = defaults.bool(forKey: Self.key)
        if isEnabled { startMonitoring() }
    }

    deinit { pollTask?.cancel() }

    private func refreshCaptureState() {
        let concealing = isEnabled && isScreenCaptured()
        guard concealing != isConcealing else { return }
        isConcealing = concealing
    }

    private func startMonitoring() {
        guard pollTask == nil else { return }
        installChangeNotifications { [weak self] in
            Task { @MainActor [weak self] in self?.refreshCaptureState() }
        }
        refreshCaptureState()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshCaptureState()
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        refreshCaptureState()
    }
}
