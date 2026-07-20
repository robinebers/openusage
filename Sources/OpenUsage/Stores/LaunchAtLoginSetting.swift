import Observation
import ServiceManagement

/// Keeps the Launch at Login switch aligned with macOS without treating a failed rollback as a
/// second user action.
@MainActor
@Observable
final class LaunchAtLoginSetting {
    static let failureMessage = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."

    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    private let currentStatus: () -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        currentStatus: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.currentStatus = currentStatus
        self.setSystemEnabled = setEnabled
        self.isEnabled = currentStatus()
    }

    func update(to enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try setSystemEnabled(enabled)
            isEnabled = currentStatus()
            errorMessage = nil
        } catch {
            AppLog.error(
                .config,
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            isEnabled = currentStatus()
            errorMessage = Self.failureMessage
        }
    }
}
