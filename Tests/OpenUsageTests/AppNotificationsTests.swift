import XCTest
import UserNotifications
@testable import OpenUsage

/// `AppNotifications` wraps `UNUserNotificationCenter`, which can't be instantiated or subclassed in a
/// unit test. Narrow authorization closures pin request memoization without a live center; the XCTest
/// short-circuit separately proves `post` / `registerAsDelegate` never schedules system work. The
/// end-to-end "one post per fired milestone" check lives in `WidgetDataStoreNotificationTests`.
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testShowHandlerIsInvokedByShow() {
        var opened = false
        MenuBarPopover.showHandler = { opened = true }
        defer { MenuBarPopover.showHandler = nil }
        MenuBarPopover.show()
        XCTAssertTrue(opened)
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

    func testRepeatedAuthorizationCallsShareOneMemoizedRequestWithoutTouchingSystemCenter() async {
        let center = CenterProbe()
        let authorization = AuthorizationProbe()
        let notifications = AppNotifications(
            centerProvider: {
                center.touched = true
                return UNUserNotificationCenter.current()
            },
            authorizationStatusProvider: { await authorization.readStatus() },
            authorizationRequestProvider: { try await authorization.request() }
        )

        let first = notifications.requestAuthorization()
        let second = notifications.requestAuthorization()
        let firstResult = await first.value
        let secondResult = await second.value
        let counts = await authorization.counts

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(counts.statusReads, 1)
        XCTAssertEqual(counts.requests, 1)
        XCTAssertFalse(center.touched)
    }

    /// A tiny reference box so the `@Sendable` provider closure can record whether it ran.
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }

    private actor AuthorizationProbe {
        private var statusReads = 0
        private var requests = 0

        func readStatus() -> UNAuthorizationStatus {
            statusReads += 1
            return .notDetermined
        }

        func request() async throws -> Bool {
            requests += 1
            await Task.yield()
            return true
        }

        var counts: (statusReads: Int, requests: Int) {
            (statusReads, requests)
        }
    }
}
