import Observation
import ServiceManagement

/// Keeps the Launch at Login switch aligned with macOS without treating a failed rollback as a
/// second user action.
@MainActor
@Observable
final class LaunchAtLoginSetting {
    static let failureMessage = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."

    private(set) var isEnabled: Bool
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    private let loadStatus: @Sendable () async -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        initialStatus: Bool = false,
        loadStatus: @escaping @Sendable () async -> Bool = {
            await Task.detached(priority: .userInitiated) {
                SMAppService.mainApp.status == .enabled
            }.value
        },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.loadStatus = loadStatus
        self.setSystemEnabled = setEnabled
        self.isEnabled = initialStatus
    }

    /// `SMAppService.status` is an XPC-backed synchronous call that can take hundreds of milliseconds.
    /// The loader performs it away from the main actor so opening Settings never waits on that round trip.
    func refreshStatus() async {
        isEnabled = await loadStatus()
        isLoading = false
    }

    func update(to enabled: Bool) {
        guard enabled != isEnabled else { return }
        let previousValue = isEnabled
        do {
            try setSystemEnabled(enabled)
            isEnabled = enabled
            errorMessage = nil
        } catch {
            AppLog.error(
                .config,
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            isEnabled = previousValue
            errorMessage = Self.failureMessage
        }
    }
}
