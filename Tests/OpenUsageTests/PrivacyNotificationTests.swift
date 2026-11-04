import UserNotifications
import XCTest
@testable import OpenUsage

@MainActor
final class PrivacyNotificationTests: XCTestCase {
    func testEnablingPrivacyWhileAuthorizationIsPendingMasksTheCapturedAccountName() async throws {
        let defaults = isolatedDefaults()
        let held = HeldResponse()
        let notifications = AppNotifications(
            authorizationStatus: {
                await held.hold()
                return .authorized
            },
            isPrivacyModeEnabled: { defaults.bool(forKey: PrivacyModeSetting.key) }
        )
        var result: UNMutableNotificationContent?
        let pending = Task {
            result = await notifications.authorizedContent(
                title: "Warning", subtitle: "Claude · private@example.com Session", body: "20% or less left for this window."
            )
        }
        await held.waitUntilHeld()
        defaults.set(true, forKey: PrivacyModeSetting.key)
        await held.release()

        await pending.value
        let content = try XCTUnwrap(result)
        XCTAssertFalse(content.subtitle.contains("private@example.com"))
        XCTAssertTrue(content.subtitle.contains("Privacy Mode"))
        XCTAssertEqual(content.title, "Warning")
        XCTAssertEqual(content.body, "20% or less left for this window.")
    }

    func testPrivacyOffPreservesTheUsageNotificationAndDeniedAuthorizationProducesNone() async throws {
        let notifications = AppNotifications(authorizationStatus: { .authorized }, isPrivacyModeEnabled: { false })
        let result = await notifications.authorizedContent(title: "Critical", subtitle: "Claude · Work Session", body: "10% left.")
        let content = try XCTUnwrap(result)
        XCTAssertEqual(content.subtitle, "Claude · Work Session")
        XCTAssertEqual(content.threadIdentifier, "openusage")

        let denied = AppNotifications(authorizationStatus: { .denied }, isPrivacyModeEnabled: { true })
        let unavailable = await denied.authorizedContent(title: "Critical", subtitle: "private@example.com", body: "10% left.")
        XCTAssertNil(unavailable)
    }
}
