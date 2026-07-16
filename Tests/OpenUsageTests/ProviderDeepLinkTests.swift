import XCTest
@testable import OpenUsage

final class ProviderDeepLinkTests: XCTestCase {
    private let knownProviderIDs: Set<String> = ["claude", "codex", "openrouter"]

    func testParsesReleaseAndDevelopmentProviderLinks() throws {
        XCTAssertEqual(
            ProviderDeepLink.parse(
                try XCTUnwrap(URL(string: "openusage://provider/claude")),
                expectedScheme: "openusage",
                knownProviderIDs: knownProviderIDs
            ),
            ProviderDeepLink(providerID: "claude")
        )
        XCTAssertEqual(
            ProviderDeepLink.parse(
                try XCTUnwrap(URL(string: "openusage-dev://provider/openrouter")),
                expectedScheme: "openusage-dev",
                knownProviderIDs: knownProviderIDs
            ),
            ProviderDeepLink(providerID: "openrouter")
        )
    }

    func testRejectsUnknownProviderAndUnsupportedURLShapes() throws {
        let invalidURLs = [
            "https://provider/claude",
            "openusage://other/claude",
            "openusage://provider/unknown",
            "openusage://provider/claude/extra",
            "openusage://provider/claude?source=widget",
            "openusage://provider/claude#fragment",
            "openusage://user@provider/claude",
        ]

        for string in invalidURLs {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertNil(
                ProviderDeepLink.parse(
                    url,
                    expectedScheme: "openusage",
                    knownProviderIDs: knownProviderIDs
                ),
                "Expected rejection for \(string)"
            )
        }
    }

    func testRejectsOtherBuildScheme() throws {
        XCTAssertNil(
            ProviderDeepLink.parse(
                try XCTUnwrap(URL(string: "openusage-dev://provider/claude")),
                expectedScheme: "openusage",
                knownProviderIDs: knownProviderIDs
            )
        )
        XCTAssertNil(
            ProviderDeepLink.parse(
                try XCTUnwrap(URL(string: "openusage://provider/claude")),
                expectedScheme: "openusage-dev",
                knownProviderIDs: knownProviderIDs
            )
        )
    }

    func testRejectsUnexpectedConfiguredScheme() throws {
        XCTAssertNil(
            ProviderDeepLink.parse(
                try XCTUnwrap(URL(string: "https://provider/claude")),
                expectedScheme: "https",
                knownProviderIDs: knownProviderIDs
            ),
            "Only the two declared OpenUsage scheme values are valid"
        )
    }

    func testDestinationRequiresEnablementAndVisibleMetricsForDashboard() {
        XCTAssertEqual(
            ProviderDeepLinkDestination.resolve(isEnabled: true, hasVisibleMetrics: true),
            .dashboard
        )
        XCTAssertEqual(
            ProviderDeepLinkDestination.resolve(isEnabled: false, hasVisibleMetrics: true),
            .customize
        )
        XCTAssertEqual(
            ProviderDeepLinkDestination.resolve(isEnabled: true, hasVisibleMetrics: false),
            .customize
        )
        XCTAssertEqual(
            ProviderDeepLinkDestination.resolve(isEnabled: false, hasVisibleMetrics: false),
            .customize
        )
    }

    @MainActor
    func testDashboardFocusRequestValidatesAndRepeatsKnownProvider() {
        let suite = "OpenUsageTests.ProviderDeepLink.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: []
        )

        XCTAssertFalse(store.requestDashboardProviderFocus("unknown"))
        XCTAssertNil(store.dashboardFocusProviderID)
        XCTAssertEqual(store.dashboardFocusRequestID, 0)

        XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
        XCTAssertEqual(store.dashboardFocusProviderID, "claude")
        XCTAssertEqual(store.dashboardFocusRequestID, 1)

        XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
        XCTAssertEqual(store.dashboardFocusRequestID, 2, "same-provider links must retrigger scrolling")
    }

    @MainActor
    func testDashboardFocusAcknowledgementOnlyClearsMatchingRequest() {
        let suite = "OpenUsageTests.ProviderDeepLink.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: []
        )

        XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
        let firstRequestID = store.dashboardFocusRequestID
        XCTAssertTrue(store.requestDashboardProviderFocus("codex"))

        store.acknowledgeDashboardProviderFocus(requestID: firstRequestID)
        XCTAssertEqual(store.dashboardFocusProviderID, "codex", "an older callback must preserve a newer request")

        store.acknowledgeDashboardProviderFocus(requestID: store.dashboardFocusRequestID)
        XCTAssertNil(store.dashboardFocusProviderID, "a handled request must not replay when the dashboard remounts")
    }
}
