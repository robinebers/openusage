import XCTest
import OpenUsageWidgetSupport

final class WidgetProviderSelectionTests: XCTestCase {
    private let providers = [
        makeProvider("claude", "Claude", enabled: false),
        makeProvider("codex", "Codex", enabled: true),
        makeProvider("codex-2", "Codex (Personal)", enabled: true),
    ]

    func testResolvesExportedIDsInRequestedOrder() {
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["codex-2", "claude"], in: providers),
            [.init(id: "codex-2", name: "Codex (Personal)"), .init(id: "claude", name: "Claude")]
        )
    }

    func testKeepsAnIDTheHostNoLongerExports() {
        // A removed account card must stay selected so the widget reports it missing instead of
        // silently falling back to another provider.
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["claude-work"], in: providers),
            [.init(id: "claude-work", name: "claude-work")]
        )
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["claude"], in: []),
            [.init(id: "claude", name: "claude")]
        )
    }

    func testSuggestsEnabledProvidersAndFallsBackToAll() {
        XCTAssertEqual(WidgetProviderSelection.suggested(in: providers).map(\.id), ["codex", "codex-2"])

        let allDisabled = [makeProvider("claude", "Claude", enabled: false), makeProvider("zai", "Z.ai", enabled: false)]
        XCTAssertEqual(WidgetProviderSelection.suggested(in: allDisabled).map(\.id), ["claude", "zai"])
    }

    func testDefaultsToFirstEnabledThenFirstExported() {
        XCTAssertEqual(WidgetProviderSelection.defaultProviderID(in: providers), "codex")
        XCTAssertEqual(
            WidgetProviderSelection.defaultProviderID(in: [makeProvider("claude", "Claude", enabled: false)]),
            "claude"
        )
        XCTAssertNil(WidgetProviderSelection.defaultProviderID(in: []))
    }

    func testUnconfiguredWidgetReportsCorruptBridge() {
        XCTAssertEqual(entry(.corrupt), .corruptData(nil))
    }

    func testUnconfiguredWidgetReportsUnsupportedBridge() {
        XCTAssertEqual(entry(.unsupported), .unsupportedData(nil))
    }

    func testBridgeErrorsKeepConfiguredProviderID() {
        let corrupt = entry(.corrupt, configuredID: "codex-2")
        let unsupported = entry(.unsupported, configuredID: "codex-2")
        XCTAssertEqual(corrupt, .corruptData("codex-2"))
        XCTAssertEqual(unsupported, .unsupportedData("codex-2"))
        XCTAssertEqual(corrupt.providerID, "codex-2")
        XCTAssertEqual(unsupported.providerID, "codex-2")
    }

    func testMissingBridgeReportsMissingDataWithOrWithoutConfiguration() {
        XCTAssertEqual(entry(.missing), .missingData(nil))
        XCTAssertEqual(entry(.missing, configuredID: "codex-2"), .missingData("codex-2"))
    }

    func testLoadedBridgeUsesEnabledDefaultForUnconfiguredWidget() {
        let selection = entry(.loaded, providers: providers)
        XCTAssertEqual(selection, .provider(providers[1]))
        XCTAssertEqual(selection.providerID, "codex")
    }

    func testLoadedBridgeKeepsConfiguredProviderEvenWhenDisabled() {
        XCTAssertEqual(
            entry(.loaded, configuredID: "claude", providers: providers),
            .provider(providers[0])
        )
    }

    func testLoadedBridgeReportsUnavailableConfiguredProvider() {
        let selection = entry(.loaded, configuredID: "claude-work", providers: providers)
        XCTAssertEqual(selection, .missingProvider("claude-work"))
        XCTAssertEqual(selection.providerID, "claude-work")
    }

    func testLoadedEmptyBridgeReportsMissingDataForUnconfiguredWidget() {
        XCTAssertEqual(entry(.loaded), .missingData(nil))
    }

    private func entry(
        _ status: WidgetBridgeReadStatus, configuredID: String? = nil, providers: [WidgetProviderRecord] = []
    ) -> WidgetProviderSelection.Entry {
        WidgetProviderSelection.entry(
            configuredID: configuredID, bridgeStatus: status, in: providers
        )
    }
}

private func makeProvider(_ id: String, _ name: String, enabled: Bool) -> WidgetProviderRecord {
    WidgetProviderRecord(
        id: id, displayName: name, iconID: nil, isEnabled: enabled, plan: nil, refreshedAt: nil,
        health: .noData, primaryMetrics: [], secondaryMetrics: []
    )
}
