import XCTest
@testable import OpenUsage

/// Anthropic renamed Max 5x to Max and Max 20x to Ultra on Oct 30, 2026 (#1497).
final class ClaudePlanTests: XCTestCase {
    private func plan(_ organizationType: String, _ rateLimitTier: String?) throws -> String? {
        let tier = rateLimitTier.map { #","rate_limit_tier":"\#($0)""# } ?? ""
        let json = #"{"account":{"uuid":"acc-1"},"organization":{"uuid":"org-1","organization_type":"\#(organizationType)"\#(tier)}}"#
        let profile = try JSONDecoder().decode(ClaudeAccountProfile.self, from: Data(json.utf8))
        return ClaudeUsageMapper.formatLivePlan(profile: profile)
    }

    func testMaxTiersReadUnderAnthropicsNewPlanNames() throws {
        XCTAssertEqual(try plan("claude_max", "default_claude_max_5x"), "Max")
        XCTAssertEqual(try plan("claude_max", "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(try plan("claude_max", nil), "Max")
    }

    func testAnUltraTierOrOrganizationReadsUltra() throws {
        XCTAssertEqual(try plan("claude_max", "default_claude_ultra"), "Ultra")
        XCTAssertEqual(try plan("claude_ultra", "default_claude_ultra"), "Ultra")
        XCTAssertEqual(try plan("claude_ultra", "default_claude_max_20x"), "Ultra")
    }

    func testOtherPlansKeepTheirNames() throws {
        XCTAssertEqual(try plan("claude_pro", "default_claude_ai"), "Pro")
        XCTAssertEqual(try plan("claude_team", "default_claude_max_5x"), "Team 5x")
        XCTAssertEqual(try plan("claude_enterprise", nil), "Enterprise")
    }
}
