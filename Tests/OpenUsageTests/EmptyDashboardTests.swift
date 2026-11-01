import XCTest
@testable import OpenUsage

@MainActor
final class EmptyDashboardTests: XCTestCase {
    func testOnlyAnInstallThat07RanOnSaysWhyItsAccountsAreGone() {
        let upgraded = isolatedDefaults()
        upgraded.set(1, forKey: "openusage.settings.schemaVersion")

        let fresh = EmptyDashboardView(defaults: isolatedDefaults()) {}.copy
        XCTAssertEqual(fresh.title, "Add an Account")
        XCTAssertEqual(
            fresh.message,
            "OpenUsage tracks however many accounts you'd like to monitor. Just add them and they'll show right up, even multiple of the same provider!"
        )

        let welcome = EmptyDashboardView(defaults: upgraded) {}.copy
        XCTAssertEqual(welcome.title, "Welcome Back")
        XCTAssertEqual(
            welcome.message,
            "OpenUsage no longer reads your local accounts automatically. Add back any account you'd like it to track. Even multiple of the same provider!"
        )
    }
}
