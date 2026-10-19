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
    func testWelcomeCompletionKeepsQueuedDisabledProviderDestination() throws {
        let url = try XCTUnwrap(URL(string: "openusage://provider/codex"))
        var screen: PopoverScreen = .settings
        var openedProviderID: String?

        AppDelegate.openInitialDestination(
            pendingURLs: [url],
            showsDashboard: true,
            openDashboard: { screen = .dashboard },
            openURL: { url in
                guard case .provider(let id) = ProviderDeepLink.parse(
                    url, expectedScheme: "openusage", knownProviderIDs: knownProviderIDs
                ) else {
                    XCTFail("Expected a known provider link")
                    return
                }
                let destination = ProviderDeepLinkDestination.resolve(isEnabled: false, hasVisibleMetrics: true)
                screen = destination == .dashboard ? .dashboard : .customize
                openedProviderID = id
            }
        )

        XCTAssertEqual(screen, .customize, "The welcome dashboard must not replace the queued widget's destination")
        XCTAssertEqual(openedProviderID, "codex")
    }

    @MainActor
    func testWelcomeCompletionWithoutWidgetLinksOpensDashboard() {
        var screen: PopoverScreen = .settings
        AppDelegate.openInitialDestination(
            pendingURLs: [],
            showsDashboard: true,
            openDashboard: { screen = .dashboard },
            openURL: { _ in XCTFail("No widget link was queued") }
        )
        XCTAssertEqual(screen, .dashboard)
    }

    @MainActor
    func testDashboardFocusRequestValidatesAndRepeatsKnownProvider() {
        withLayoutStore { store in
            XCTAssertFalse(store.requestDashboardProviderFocus("unknown"))
            XCTAssertNil(store.dashboardFocusProviderID)
            XCTAssertEqual(store.dashboardFocusRequestID, 0)

            XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
            XCTAssertEqual(store.dashboardFocusProviderID, "claude")
            XCTAssertEqual(store.dashboardFocusRequestID, 1)

            XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
            XCTAssertEqual(store.dashboardFocusRequestID, 2, "same-provider links must retrigger scrolling")
        }
    }

    @MainActor
    func testDashboardFocusAcknowledgementOnlyClearsMatchingRequest() {
        withLayoutStore { store in
            XCTAssertTrue(store.requestDashboardProviderFocus("claude"))
            let firstRequestID = store.dashboardFocusRequestID
            XCTAssertTrue(store.requestDashboardProviderFocus("codex"))

            store.acknowledgeDashboardProviderFocus(requestID: firstRequestID)
            XCTAssertEqual(store.dashboardFocusProviderID, "codex", "an older callback must preserve a newer request")

            store.acknowledgeDashboardProviderFocus(requestID: store.dashboardFocusRequestID)
            XCTAssertNil(store.dashboardFocusProviderID, "a handled request must not replay when the dashboard remounts")
        }
    }

    private func parse(_ string: String, scheme: String = "openusage") throws -> ProviderDeepLink? {
        ProviderDeepLink.parse(
            try XCTUnwrap(URL(string: string)), expectedScheme: scheme, knownProviderIDs: knownProviderIDs
        )
    }

    @MainActor
    private func withLayoutStore(_ assertions: (LayoutStore) -> Void) {
        let suite = "OpenUsageTests.ProviderDeepLink.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout", defaultMetricIDs: [])
        assertions(store)
    }
}
