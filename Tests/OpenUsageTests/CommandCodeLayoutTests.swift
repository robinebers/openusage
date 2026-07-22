import XCTest
@testable import OpenUsage

@MainActor
final class CommandCodeLayoutTests: XCTestCase {
    private let orderedMetricIDs = [
        "commandcode.fiveHour",
        "commandcode.weekly",
        "commandcode.monthly",
        "commandcode.balance",
        "commandcode.requests"
    ]

    func testApprovedDefaultPlacement() {
        for id in orderedMetricIDs {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }

        for id in orderedMetricIDs.prefix(3) {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should stay Always Visible")
        }
        for id in orderedMetricIDs.suffix(2) {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should start On Demand")
        }

        XCTAssertEqual(
            DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("commandcode.") },
            ["commandcode.fiveHour", "commandcode.weekly"]
        )
    }

    func testProviderDeclaresApprovedMetricOrder() {
        XCTAssertEqual(CommandCodeProvider().widgetDescriptors.map(\.id), orderedMetricIDs)
    }

    func testProviderUsesCanonicalTailOrder() {
        let defaults = UserDefaults(suiteName: "CommandCodeLayoutTests.\(UUID().uuidString)")!
        let providerNames = ProviderCatalog.make(defaults: defaults).map(\.provider.displayName)
        guard let antigravity = providerNames.firstIndex(of: "Antigravity"),
              let commandCode = providerNames.firstIndex(of: "Command Code"),
              let copilot = providerNames.firstIndex(of: "Copilot")
        else {
            return XCTFail("expected Antigravity, Command Code, and Copilot in ProviderCatalog")
        }
        XCTAssertLessThan(antigravity, commandCode)
        XCTAssertLessThan(commandCode, copilot)
    }
}
