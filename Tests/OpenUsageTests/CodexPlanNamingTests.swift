import XCTest
@testable import OpenUsage

final class CodexPlanNamingTests: XCTestCase {
    func testMapsProPlanIdentifiersFromUsageResponse() throws {
        let cases = [
            ("prolite", "Pro 100"),
            ("pro", "Pro 200"),
            ("promax", "Pro 500"),
            ("  PROLITE\n", "Pro 100"),
            (" PRO ", "Pro 200"),
            (" ProMax ", "Pro 500")
        ]

        for (raw, expected) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["plan_type": raw])
            let mapped = try CodexUsageMapper.mapUsageResponse(
                HTTPResponse(statusCode: 200, headers: [:], body: body)
            )

            XCTAssertEqual(mapped.plan, expected, raw)
        }
    }

    func testPreservesOtherPlansAndUnknownEntitlements() {
        let cases = [
            ("free", "Free"),
            ("plus", "Plus"),
            ("team", "Team"),
            ("business", "Business"),
            ("self_serve_business_prolite", "Business Premium"),
            ("self_serve_business", "Self Serve Business"),
            ("self_serve_business_prolite_future", "Self Serve Business Prolite Future"),
            ("promax_future", "Promax Future"),
            ("future_plan", "Future Plan")
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(CodexUsageMapper.formatCodexPlan(raw), expected, raw)
        }
    }

    func testMissingOrInvalidPlanDoesNotInventAPlanName() throws {
        let cases: [[String: Any]] = [
            [:],
            ["plan_type": NSNull()],
            ["plan_type": ""],
            ["plan_type": " \n"],
            ["plan_type": 500]
        ]

        for body in cases {
            let response = HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: try JSONSerialization.data(withJSONObject: body)
            )
            XCTAssertNil(try CodexUsageMapper.mapUsageResponse(response).plan)
        }
    }
}
