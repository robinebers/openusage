import XCTest
@testable import OpenUsage

/// A long-lived Claude token reads its limits from the headers of a model request.
final class ClaudeTokenLimitsTests: XCTestCase {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data())
    }

    func testWindowsOnTheHeadersBecomeSessionAndWeeklyLines() throws {
        let lines = try ClaudeUsageMapper.mapLimitHeaders(response(200, [
            "anthropic-ratelimit-unified-5h-utilization": "0.07",
            "anthropic-ratelimit-unified-5h-reset": "1794760000",
            "anthropic-ratelimit-unified-7d-utilization": "0.31",
            "anthropic-ratelimit-unified-7d-reset": "1794963600"
        ]))
        XCTAssertEqual(lines, [
            .percent("Session", 7, resetsAt: Date(timeIntervalSince1970: 1_794_760_000), periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 31, resetsAt: Date(timeIntervalSince1970: 1_794_963_600), periodMs: MetricPeriod.weekMs)
        ])
    }

    func testFablesWeeklyWindowBecomesTheFableLine() throws {
        let fable = response(200, [
            "anthropic-ratelimit-unified-7d-utilization": "0.31",
            "anthropic-ratelimit-unified-7d-reset": "1794963600",
            "anthropic-ratelimit-unified-7d_oi-utilization": "0.11",
            "anthropic-ratelimit-unified-7d_oi-reset": "1794963600"
        ])
        XCTAssertTrue(ClaudeUsageMapper.hasLimitHeaders(fable))
        XCTAssertFalse(ClaudeUsageMapper.hasLimitHeaders(response(404)))
        XCTAssertEqual(try ClaudeUsageMapper.mapLimitHeaders(fable), [
            .percent("Weekly", 31, resetsAt: Date(timeIntervalSince1970: 1_794_963_600), periodMs: MetricPeriod.weekMs),
            .percent("Fable", 11, resetsAt: Date(timeIntervalSince1970: 1_794_963_600), periodMs: MetricPeriod.weekMs)
        ])
    }

    func testAWindowAnthropicLeavesOutAddsNoLine() throws {
        let lines = try ClaudeUsageMapper.mapLimitHeaders(response(200, [
            "anthropic-ratelimit-unified-7d-utilization": "0.31",
            "anthropic-ratelimit-unified-7d-reset": "1794963600"
        ]))
        XCTAssertEqual(lines.count, 1)
    }

    func testAnAccountAtItsLimitStillShowsItsWindows() throws {
        let lines = try ClaudeUsageMapper.mapLimitHeaders(response(429, [
            "anthropic-ratelimit-unified-7d-utilization": "1.02",
            "anthropic-ratelimit-unified-7d-reset": "1794963600"
        ]))
        XCTAssertEqual(lines, [
            .percent("Weekly", 100, resetsAt: Date(timeIntervalSince1970: 1_794_963_600), periodMs: MetricPeriod.weekMs)
        ])
    }

    func testARefusedTokenAsksForAReplacement() {
        XCTAssertThrowsError(try ClaudeUsageMapper.mapLimitHeaders(response(401))) {
            XCTAssertEqual($0 as? ProviderError, .keyRejected("Claude rejected the token."))
        }
    }

    func testAnAnswerWithoutLimitsIsNotAnEmptyAccount() {
        XCTAssertThrowsError(try ClaudeUsageMapper.mapLimitHeaders(response(200))) {
            XCTAssertEqual($0 as? ProviderError, .unavailable("Claude reported no usage limits for this token."))
        }
        XCTAssertThrowsError(try ClaudeUsageMapper.mapLimitHeaders(response(500))) {
            XCTAssertEqual($0 as? ProviderError, .requestFailed(500))
        }
    }
}
