import XCTest
@testable import OpenUsage

final class CopilotOrgBillingMapperTests: XCTestCase {
    func testParsesOrgLogins() {
        let body: [[String: Any]] = [["login": "acme", "id": 1], ["login": "globex"], ["id": 3]]
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: body)
        )

        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), ["acme", "globex"])
    }

    func testOrgLoginsEmptyForGarbledBody() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8))
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), [])
    }

    func testMapsAICreditUsageFromSummary() throws {
        // The exact shape reported in issue #839: one Copilot AI-unit item, fully covered by included
        // credits (netAmount 0).
        let lines = try XCTUnwrap(
            CopilotOrgBillingMapper.usageLines(body: CopilotTestFixtures.orgSummaryBody())
        )

        XCTAssertEqual(CopilotTestFixtures.orgCount(lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(CopilotTestFixtures.orgDollars(lines, "Org Spend"), 0)
    }

    func testSumsMultipleCreditItemsAndBilledSpend() throws {
        var body = CopilotTestFixtures.orgSummaryBody()
        body["usageItems"] = [
            ["product": "Copilot", "sku": "copilot_ai_unit", "unitType": "ai-units", "grossQuantity": 100.5, "netAmount": 1.25],
            ["product": "Copilot", "sku": "Copilot AI Credits", "unitType": "ai-credits", "grossQuantity": 50, "netAmount": 0.5]
        ]

        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: body))

        XCTAssertEqual(CopilotTestFixtures.orgCount(lines, "Org Credits") ?? -1, 150.5, accuracy: 0.0001)
        XCTAssertEqual(CopilotTestFixtures.orgDollars(lines, "Org Spend") ?? -1, 1.75, accuracy: 0.0001)
    }

    func testNilWhenNoCopilotCreditItems() {
        // Actions minutes and Copilot seat fees (non-credit units) must not produce org meters.
        var body = CopilotTestFixtures.orgSummaryBody()
        body["usageItems"] = [
            ["product": "Actions", "sku": "actions_linux", "unitType": "minutes", "grossQuantity": 120, "netAmount": 0.96],
            ["product": "Copilot", "sku": "copilot_business_seat", "unitType": "user-months", "grossQuantity": 10, "netAmount": 190]
        ]

        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: body))
    }

    func testNilWhenSummaryHasNoUsageItems() {
        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: ["organization": "acme"]))
    }
}
