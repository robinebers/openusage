import XCTest
@testable import OpenUsage

/// `AppNotifications` wraps `UNUserNotificationCenter`, which can't be instantiated or subclassed in a
/// unit test. The behavior we can pin without a live center is the test short-circuit: under XCTest,
/// `post` never delivers (no prompt, no scheduled notification). The end-to-end "one post per fired
/// milestone" check lives in `WidgetDataStoreNotificationTests`, which injects a recording sink into the
/// store.
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testPostReturnsFalseUnderTests() async {
        let delivered = await AppNotifications.shared.post(idPrefix: "claude.session.healthyToClose", title: "Cutting It Close", subtitle: "Claude Session", body: "x")
        XCTAssertFalse(delivered)
    }
}
