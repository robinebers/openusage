import XCTest
import UserNotifications
@testable import OpenUsage

/// `AppNotifications` wraps `UNUserNotificationCenter`, which can't be instantiated or subclassed in a
/// unit test. The behavior we can pin without a live center is the test short-circuit: under XCTest,
/// `post` / `registerAsDelegate` must never touch the center (no prompt, no scheduled notification), so
/// the injected center provider is never invoked. The end-to-end "one post per fired milestone" check
/// lives in `WidgetDataStoreNotificationTests`, which injects a recording sink into the store.
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testPostIsANoOpUnderTestsAndNeverTouchesTheCenter() async {
        let probe = CenterProbe()
        let notifications = AppNotifications(centerProvider: {
            probe.touched = true
            return UNUserNotificationCenter.current()
        })
        _ = await notifications.post(idPrefix: "claude.session.healthyToClose", title: "Cutting It Close", subtitle: "Claude Session", body: "x")
        notifications.registerAsDelegate()
        XCTAssertFalse(probe.touched, "Under tests, no notification path should reach the center provider")
    }

    /// A tiny reference box so the `@Sendable` provider closure can record whether it ran.
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }
}
