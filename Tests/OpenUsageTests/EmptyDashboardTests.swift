import XCTest
@testable import OpenUsage

@MainActor
final class EmptyDashboardTests: XCTestCase {
    func testOnlyAnInstallThat07RanOnSaysWhyItsAccountsAreGone() {
        let upgraded = isolatedDefaults()
        upgraded.set(1, forKey: "openusage.settings.schemaVersion")

        XCTAssertEqual(EmptyDashboardView(defaults: isolatedDefaults()) {}.subtitle, "Sign in to see your usage limits.")
        XCTAssertEqual(
            EmptyDashboardView(defaults: upgraded) {}.subtitle,
            "OpenUsage no longer reads other apps' sign-ins. Add your accounts again."
        )
    }
}
