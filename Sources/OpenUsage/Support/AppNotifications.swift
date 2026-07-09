import AppKit
import Foundation
import UserNotifications

/// The single entry point for posting macOS user notifications. Quota pace alerts go through `post`;
/// authorization is requested when the first Settings trigger is turned on (all default off, so a
/// fresh install stays quiet until the user opts in).
///
/// Authorization is memoized in one `Task<Bool, Never>`: the first caller reads the current settings,
/// short-circuits an already-authorized or already-denied state, and otherwise requests it; every later
/// caller awaits the same task rather than re-prompting. The class is the notification-center delegate so
/// banners still show while the app is frontmost (a menu-bar accessory usually is).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    /// Injectable so tests can supply a fake center and assert what got scheduled. Production returns
    /// the system `current()` center.
    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    /// Narrow authorization seams keep memoization testable without constructing or touching the live
    /// `UNUserNotificationCenter`, which cannot be instantiated or subclassed in a unit test.
    private let authorizationStatusProvider: @Sendable () async -> UNAuthorizationStatus
    private let authorizationRequestProvider: @Sendable () async throws -> Bool

    /// Memoized authorization request — created on first use, awaited by everyone after.
    private var authorizationTask: Task<Bool, Never>?

    init(
        centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = {
            UNUserNotificationCenter.current()
        },
        authorizationStatusProvider: (@Sendable () async -> UNAuthorizationStatus)? = nil,
        authorizationRequestProvider: (@Sendable () async throws -> Bool)? = nil
    ) {
        self.centerProvider = centerProvider
        self.authorizationStatusProvider = authorizationStatusProvider ?? {
            await centerProvider().notificationSettings().authorizationStatus
        }
        self.authorizationRequestProvider = authorizationRequestProvider ?? {
            try await centerProvider().requestAuthorization(options: [.alert, .sound])
        }
        super.init()
    }

    /// True while running inside the XCTest harness, so a unit test never actually schedules a system
    /// notification or trips the authorization prompt. (No XCTest symbol is linked into the app target,
    /// so this is a runtime class lookup.)
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Make this object the delegate at launch. Authorization remains deferred until a Settings trigger
    /// is enabled; this method is a no-op under tests.
    func registerAsDelegate() {
        guard !Self.isRunningUnderTests else { return }
        centerProvider().delegate = self
    }

    /// Request notification authorization. Called when the first trigger turns on and from Settings'
    /// "Allow Notifications" button while permission is still not determined. Memoized, so repeated
    /// callers await one system prompt and macOS is never asked twice.
    @discardableResult
    func requestAuthorization() -> Task<Bool, Never> {
        ensureAuthorization()
    }

    /// Open System Settings → Notifications so the user can re-enable alerts for OpenUsage after a
    /// macOS-level denial (the app can't re-prompt once the system has cached a decision). No-op under
    /// tests.
    func openSystemNotificationsSettings() {
        guard !Self.isRunningUnderTests else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Post one immediate notification. `idPrefix` names the source (e.g. a metric key) for the log line;
    /// the actual identifier is made unique so repeated alerts on the same metric don't coalesce. `title`
    /// is the alert headline, `subtitle` carries provider + metric, and `body` is the verdict. Returns
    /// whether it was actually delivered — false under tests, when not authorized, or when scheduling
    /// errors, so the caller can leave the milestone un-marked and retry. A cached denial is re-checked
    /// live so a user re-enabling notifications in System Settings doesn't have to restart the app to
    /// receive alerts.
    func post(idPrefix: String, title: String, subtitle: String, body: String, soundEnabled: Bool = true) async -> Bool {
        guard !Self.isRunningUnderTests else { return false }
        var authorized = await ensureAuthorization().value
        if !authorized {
            // A cached denial may be stale — the user can re-enable notifications in System Settings
            // at any time. Re-read the live status; if it's now authorized, refresh the cache and
            // proceed instead of skipping delivery until an app restart.
            let status = await centerProvider().notificationSettings().authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                authorized = true
                authorizationTask = Task<Bool, Never> { true }
            default:
                AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
                return false
            }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // Group all OpenUsage alerts into one stacked thread so simultaneous alerts (e.g. a metric
        // that fires two milestones at once) collapse into a single banner with a "N more" summary
        // instead of separate banners.
        content.threadIdentifier = "openusage"
        if soundEnabled { content.sound = .default }
        let id = "openusage-\(idPrefix)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await centerProvider().add(request)
            AppLog.info(.notifications, "posted \(idPrefix)")
            return true
        } catch {
            AppLog.error(.notifications, "post \(idPrefix) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Authorization

    /// The shared authorization task, created on first call. Reads current settings, short-circuits a
    /// resolved (authorized/denied) state, and otherwise requests alert + sound permission.
    private func ensureAuthorization() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let authorizationStatusProvider = authorizationStatusProvider
        let authorizationRequestProvider = authorizationRequestProvider
        let task = Task<Bool, Never> {
            switch await authorizationStatusProvider() {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                AppLog.info(.notifications, "authorization denied")
                return false
            case .notDetermined:
                do {
                    let granted = try await authorizationRequestProvider()
                    AppLog.info(.notifications, "authorization \(granted ? "granted" : "refused")")
                    return granted
                } catch {
                    AppLog.error(.notifications, "authorization request failed: \(error.localizedDescription)")
                    return false
                }
            @unknown default:
                return false
            }
        }
        authorizationTask = task
        return task
    }

    /// Current authorization status, for the Settings screen's denied-permission notice. Returns
    /// `.notDetermined` under tests.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard !Self.isRunningUnderTests else { return .notDetermined }
        return await centerProvider().notificationSettings().authorizationStatus
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner (and play sound) even when the app is frontmost — a menu-bar accessory is
    /// effectively always frontmost, so without this the user would never see the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping a pace alert opens the menu-bar popover so the user lands on the dashboard.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.threadIdentifier == "openusage"
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            AppLog.info(.notifications, "notification tapped; opening popover")
            MenuBarPopover.show()
        }
        completionHandler()
    }
}
