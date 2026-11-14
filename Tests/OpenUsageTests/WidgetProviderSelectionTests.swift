import XCTest
import OpenUsageWidgetSupport

final class WidgetProviderSelectionTests: XCTestCase {
    private let providers = [
        makeProvider("claude@00000001", "Claude · Work"),
        makeProvider("codex@00000002", "ChatGPT · Work"),
        makeProvider("codex@00000003", "ChatGPT · Personal"),
    ]

    func testResolvesDistinctAccountsInRequestedOrder() {
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["codex@00000003", "claude@00000001"], in: providers),
            [.init(id: "codex@00000003", name: "ChatGPT · Personal"), .init(id: "claude@00000001", name: "Claude · Work")]
        )
    }

    func testKeepsAnIDTheHostNoLongerExports() {
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["claude@removed"], in: providers),
            [.init(id: "claude@removed", name: "claude@removed")]
        )
        XCTAssertEqual(
            WidgetProviderSelection.resolve(["claude@00000001"], in: []),
            [.init(id: "claude@00000001", name: "claude@00000001")]
        )
    }

    func testDefaultsToFirstAccountInExportedOrder() {
        XCTAssertEqual(WidgetProviderSelection.defaultProviderID(in: providers), "claude@00000001")
        XCTAssertEqual(WidgetProviderSelection.defaultProviderID(in: Array(providers.reversed())), "codex@00000003")
        XCTAssertNil(WidgetProviderSelection.defaultProviderID(in: []))
    }

    func testUnconfiguredWidgetReportsCorruptAndUnsupportedBridgeBeforeChoosingAnAccount() {
        XCTAssertEqual(entry(.corrupt), .corruptData(nil))
        XCTAssertEqual(entry(.unsupported), .unsupportedData(nil))
    }

    func testBridgeErrorsKeepConfiguredAccountID() {
        let corrupt = entry(.corrupt, configuredID: "codex@00000003")
        let unsupported = entry(.unsupported, configuredID: "codex@00000003")
        XCTAssertEqual(corrupt, .corruptData("codex@00000003"))
        XCTAssertEqual(unsupported, .unsupportedData("codex@00000003"))
        XCTAssertEqual(corrupt.providerID, "codex@00000003")
        XCTAssertEqual(unsupported.providerID, "codex@00000003")
    }

    func testMissingBridgeReportsMissingDataWithOrWithoutConfiguration() {
        XCTAssertEqual(entry(.missing), .missingData(nil))
        XCTAssertEqual(entry(.missing, configuredID: "codex@00000003"), .missingData("codex@00000003"))
    }

    func testLoadedBridgeUsesFirstSavedAccountForUnconfiguredWidget() {
        let selection = entry(.loaded, providers: providers)
        XCTAssertEqual(selection, .provider(providers[0]))
        XCTAssertEqual(selection.providerID, "claude@00000001")
    }

    func testLoadedBridgeKeepsConfiguredAccountInsteadOfSwitchingToTheDefault() {
        XCTAssertEqual(entry(.loaded, configuredID: "codex@00000003", providers: providers), .provider(providers[2]))
    }

    func testLoadedBridgeReportsUnavailableConfiguredAccount() {
        let selection = entry(.loaded, configuredID: "claude@removed", providers: providers)
        XCTAssertEqual(selection, .missingProvider("claude@removed"))
        XCTAssertEqual(selection.providerID, "claude@removed")
    }

    func testLoadedEmptyBridgeReportsMissingDataForUnconfiguredWidget() {
        XCTAssertEqual(entry(.loaded), .missingData(nil))
    }

    private func entry(
        _ status: WidgetBridgeReadStatus, configuredID: String? = nil, providers: [WidgetProviderRecord] = []
    ) -> WidgetProviderSelection.Entry {
        WidgetProviderSelection.entry(configuredID: configuredID, bridgeStatus: status, in: providers)
    }
}

private func makeProvider(_ id: String, _ name: String) -> WidgetProviderRecord {
    WidgetProviderRecord(
        id: id, displayName: name, iconID: nil, plan: nil, refreshedAt: nil, health: .noData, metrics: []
    )
}
