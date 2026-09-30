import XCTest
@testable import OpenUsage

/// The Claude "Rate Limit Resets" row, read from the usage body's `cedar_ember` block (Anthropic's one-off
/// usage-limit reset grants). Read-only for now: no claim flow.
final class ClaudeResetGrantsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func resetsLine(_ json: String) throws -> MetricLine? {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: ClaudeOAuth(subscriptionType: "max"), now: now)
        return mapped.lines.first { line in
            if case .values(let label, _, _, _, _, _) = line { return label == "Rate Limit Resets" }
            return false
        }
    }

    private func countAndExpiries(_ line: MetricLine?) -> (Double?, [Date])? {
        guard case .values(_, let values, _, let expiries, _, _) = line else { return nil }
        return (values.first?.number, expiries)
    }

    func testMapsEachRemainingResetWithItsGrantDeadline() throws {
        // Shape from a live Max 20x response (the Opus 5.5 launch grant), plus a second grant with two
        // resets left so both share one deadline.
        let line = try resetsLine("""
        { "cedar_ember": {
            "eligible": true, "at_limit": false, "exhausted": [],
            "grants": [
              { "id": "opus55-launch-promax-20260921", "resets_total": 1, "resets_left": 1,
                "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00",
                "clears": ["five_hour", "seven_day"], "paused": false, "usable_now": true },
              { "id": "other", "resets_total": 2, "resets_left": 2, "ends_at": "2026-10-01T00:00:00+00:00" },
              { "id": "spent", "resets_total": 1, "resets_left": 0, "ends_at": "2026-10-05T00:00:00+00:00" },
              { "id": "lapsed", "resets_total": 1, "resets_left": 1, "ends_at": "2026-09-01T00:00:00+00:00" }
            ],
            "next_grant_id": "opus55-launch-promax-20260921" } }
        """)

        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 3)
        XCTAssertEqual(expiries, [
            OpenUsageISO8601.date(from: "2026-10-01T00:00:00+00:00")!,
            OpenUsageISO8601.date(from: "2026-10-01T00:00:00+00:00")!,
            OpenUsageISO8601.date(from: "2026-10-22T16:00:00+00:00")!
        ])
    }

    func testGrantWithoutDeadlineCountsWithNoExpiry() throws {
        let line = try resetsLine(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":1,"ends_at":null}]}}"#)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(expiries, [])
    }

    func testIneligibleAccountReadsZeroAvailable() throws {
        let line = try resetsLine(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"tier","grants":[{"id":"g","resets_left":1}]}}"#)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(expiries, [])
    }

    func testMissingOrNullBlockEmitsNoRow() throws {
        XCTAssertNil(try resetsLine(#"{"cedar_ember":null}"#))
        XCTAssertNil(try resetsLine(#"{"five_hour":{"utilization":3}}"#))
    }

    func testUsageRequestOptsInToResetGrants() {
        let url = ClaudeUsageClient.usageURLWithResetGrants(URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
    }

    func testUsageRequestIdentifiesAsClaudeCode() async throws {
        // Anthropic gates reset grants by client surface: an unrecognized User-Agent (we used to send
        // `claude-code/2.1.69`) comes back `eligible: false, ineligible_reason: "surface"` with no grants.
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let config = ClaudeOAuthConfig(
            usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            refreshURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            clientID: "client"
        )
        _ = try await ClaudeUsageClient(httpClient: http).fetchUsage(accessToken: "token", config: config)
        let userAgent = try XCTUnwrap(http.requests.first?.headers["User-Agent"])
        XCTAssertTrue(userAgent.hasPrefix("claude-cli/"), userAgent)
        XCTAssertTrue(userAgent.hasSuffix("(external, cli)"), userAgent)
    }

    func testPopoverEntriesStayDistinctWhenResetsShareADeadline() {
        let deadline = now.addingTimeInterval(10 * 86_400)
        let entries = RateLimitResetsDetail.entries(from: [deadline, deadline], now: now)
        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
    }
}
