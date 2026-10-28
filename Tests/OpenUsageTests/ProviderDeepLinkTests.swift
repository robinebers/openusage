import XCTest
@testable import OpenUsage

final class ProviderDeepLinkTests: XCTestCase {
    private let knownProviderIDs: Set<String> = ["claude", "codex", "codex@active", "openrouter"]

    func testParsesReleaseAndDevelopmentProviderLinks() throws {
        XCTAssertEqual(try parse("openusage://provider/claude"), .provider("claude"))
        XCTAssertEqual(
            try parse("openusage-dev://provider/openrouter", scheme: "openusage-dev"),
            .provider("openrouter")
        )
    }

    func testRoutesMissingAndRemovedProvidersToRecovery() throws {
        for scheme in ["openusage", "openusage-dev"] {
            for path in ["", "/", "/unknown", "/codex@removed"] {
                XCTAssertEqual(
                    try parse("\(scheme)://provider\(path)", scheme: scheme),
                    .recovery,
                    "Expected dashboard recovery for \(scheme)://provider\(path)"
                )
            }
            XCTAssertEqual(
                try parse("\(scheme)://provider/codex@active", scheme: scheme),
                .provider("codex@active"),
                "An account still in the registry must retain its provider destination"
            )
        }
    }

    func testRejectsUnsupportedURLShapes() throws {
        let invalidURLs = [
            "https://provider/claude",
            "openusage://other/claude",
            "openusage://provider/claude/extra",
            "openusage://provider/unknown/extra",
            "openusage://provider/claude?source=widget",
            "openusage://provider/claude#fragment",
            "openusage://user@provider/claude",
            "openusage://user:password@provider/claude",
            "openusage://provider:123/claude",
            "openusage://provider?source=widget",
            "openusage://provider#fragment",
        ]

        for string in invalidURLs {
            XCTAssertNil(try parse(string), "Expected rejection for \(string)")
        }
    }

    func testRejectsOtherBuildScheme() throws {
        XCTAssertNil(try parse("openusage-dev://provider/claude"))
        XCTAssertNil(try parse("openusage://provider/claude", scheme: "openusage-dev"))
    }

    func testRejectsUnexpectedConfiguredScheme() throws {
        XCTAssertNil(
            try parse("https://provider/claude", scheme: "https"),
            "Only the two declared OpenUsage scheme values are valid"
        )
    }

    @MainActor
    func testAccountLinksUseDashboardOrAccountDetailAndRecoveryClearsFocus() throws {
        let popover = PopoverState()
        popover.screen = .settings
        popover.openWidgetAccount("codex@active", hasVisibleMetrics: true)
        XCTAssertEqual(popover.screen, .dashboard)
        XCTAssertEqual(popover.dashboardFocusProviderID, "codex@active")
        let firstRequest = popover.dashboardFocusRequestID

        popover.openWidgetAccount("codex@active", hasVisibleMetrics: true)
        XCTAssertGreaterThan(popover.dashboardFocusRequestID, firstRequest)
        popover.acknowledgeDashboardFocus(requestID: firstRequest)
        XCTAssertEqual(popover.dashboardFocusProviderID, "codex@active")
        popover.acknowledgeDashboardFocus(requestID: popover.dashboardFocusRequestID)
        XCTAssertNil(popover.dashboardFocusProviderID)

        popover.openWidgetAccount("codex@active", hasVisibleMetrics: false)
        XCTAssertEqual(popover.screen, .accounts)
        XCTAssertEqual(popover.customizeProviderID, "codex@active")
        XCTAssertNil(popover.dashboardFocusProviderID)

        popover.openWidgetAccount(nil, hasVisibleMetrics: false)
        XCTAssertEqual(popover.screen, .dashboard)
        XCTAssertNil(popover.customizeProviderID)
        XCTAssertNil(popover.dashboardFocusProviderID)
    }

    @MainActor
    func testWidgetLinkDismissesAnOpenAddAccountSheet() {
        let popover = PopoverState()
        popover.screen = .accounts
        popover.isAddingAccount = true
        popover.openWidgetAccount("codex@active", hasVisibleMetrics: false)
        XCTAssertFalse(popover.isAddingAccount)
        XCTAssertEqual(popover.customizeProviderID, "codex@active")
    }

    private func parse(_ string: String, scheme: String = "openusage") throws -> ProviderDeepLink? {
        ProviderDeepLink.parse(
            try XCTUnwrap(URL(string: string)), expectedScheme: scheme, knownProviderIDs: knownProviderIDs
        )
    }
}
