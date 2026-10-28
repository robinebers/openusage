import AppKit
import Foundation
import UserNotifications

/// The single entry point for posting macOS user notifications. Quota alerts go through `post`;
/// authorization is requested when the user first enables a trigger (all default off), while `post`
/// also checks authorization before delivery.
///
/// Authorization is memoized in one `Task<Bool, Never>`: the first caller reads the current settings,
/// short-circuits an already-authorized or already-denied state, and otherwise requests it; every later
/// caller awaits the same task rather than re-prompting. A denial clears the memo, so the next caller
/// re-reads the settings and a user who re-enables notifications in System Settings needn't restart the
/// app. The class is the notification-center delegate so banners still show while the app is frontmost
/// (a menu-bar accessory usually is).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    /// Memoized authorization request — created on first use, awaited by everyone after.
    private var authorizationTask: Task<Bool, Never>?
    /// Opens the popover on the dashboard when the user taps an alert.
    private var onTap: (() -> Void)?

    /// True while running inside the XCTest harness, so a unit test never actually schedules a system
    /// notification or trips the authorization prompt. (No XCTest symbol is linked into the app target,
    /// so this is a runtime class lookup.)
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Make this object the delegate at launch so banners can display while the app is frontmost, and
    /// run `onTap` when the user taps an alert. Authorization remains on demand.
    func registerAsDelegate(onTap: @escaping () -> Void) {
        self.onTap = onTap
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post one immediate notification. `idPrefix` names the source (e.g. a metric key) for the log line;
    /// the actual identifier is made unique so repeated alerts on the same metric don't coalesce. `title`
    /// is the alert headline, `subtitle` carries provider + metric, and `body` is the verdict. Returns
    /// whether it was actually delivered — false under tests, when not authorized, or when scheduling
    /// errors, so the caller can leave the milestone un-marked and retry.
    func post(idPrefix: String, title: String, subtitle: String, body: String) async -> Bool {
        guard !Self.isRunningUnderTests else { return false }
        guard await requestAuthorization().value else {
            AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // Group all OpenUsage alerts into one stacked thread so simultaneous alerts (e.g. a metric
        // that fires two milestones at once) collapse into a single banner with a "N more" summary
        // instead of separate banners.
        content.threadIdentifier = "openusage"
        content.sound = .default
        let id = "openusage-\(idPrefix)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            AppLog.info(.notifications, "posted \(idPrefix)")
            return true
        } catch {
            AppLog.error(.notifications, "post \(idPrefix) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Authorization

    /// The shared authorization task, created on first call. Reads current settings, short-circuits a
    /// resolved (authorized/denied) state, and otherwise requests alert + sound permission. Called when
    /// the first trigger is enabled, from the Settings "Allow Notifications" button, and before each post.
    @discardableResult
    func requestAuthorization() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let center = UNUserNotificationCenter.current()
        let task = Task<Bool, Never> {
            let granted: Bool
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                granted = true
            case .denied:
                AppLog.debug(.notifications, "authorization denied")
                granted = false
            case .notDetermined:
                do {
                    granted = try await center.requestAuthorization(options: [.alert, .sound])
                    AppLog.info(.notifications, "authorization \(granted ? "granted" : "refused")")
                } catch {
                    AppLog.error(.notifications, "authorization request failed: \(error.localizedDescription)")
                    granted = false
                }
            @unknown default:
                granted = false
            }
            if !granted { authorizationTask = nil }
            return granted
        }
        authorizationTask = task
        return task
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
            self.onTap?()
        }
        completionHandler()
    }
}
