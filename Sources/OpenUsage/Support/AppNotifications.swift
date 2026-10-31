import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    private var onTap: (() -> Void)?
    private let authorizationStatus: () async -> UNAuthorizationStatus

    init(authorizationStatus: @escaping () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }) {
        self.authorizationStatus = authorizationStatus
    }

    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func registerAsDelegate(onTap: @escaping () -> Void) {
        self.onTap = onTap
        UNUserNotificationCenter.current().delegate = self
    }

    func post(idPrefix: String, title: String, subtitle: String, body: String) async -> Bool {
        guard !Self.isRunningUnderTests else { return false }
        guard await requestAuthorization() else {
            AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
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

    func requestAuthorization() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            AppLog.debug(.notifications, "authorization denied")
            return false
        case .notDetermined:
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
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

    /// Show the banner (and play sound) even when the app is frontmost — a menu-bar accessory is
    /// effectively always frontmost, so without this the user would never see the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

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
