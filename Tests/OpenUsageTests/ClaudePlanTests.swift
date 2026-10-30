import XCTest
@testable import OpenUsage

final class ClaudePlanTests: XCTestCase {
    func testMaxTiersReadAsMaxAndUltra() {
        func plan(_ type: String, _ tier: String?) -> String? {
            ClaudeUsageMapper.formatPlan(subscriptionType: type, rateLimitTier: tier)
        }
        XCTAssertEqual(plan("max", "default_claude_max_5x"), "Max")
        XCTAssertEqual(plan("max", "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(plan("max", nil), "Max")
        XCTAssertEqual(plan("ultra", "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(plan("pro", nil), "Pro")
    }

    func testAnUltraAccountWithoutA5HourLimitHasNoSessionLine() throws {
        let lines = try ClaudeUsageMapper.mapUsageResponse(HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"five_hour":null,"seven_day":{"utilization":9,"resets_at":"2026-11-05T15:00:00Z"}}"#.utf8)
        ))
        XCTAssertEqual(lines.map(\.label), ["Weekly"])
    }
}
