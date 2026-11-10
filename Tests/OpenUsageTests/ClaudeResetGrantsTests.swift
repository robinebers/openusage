import XCTest
@testable import OpenUsage

/// The Claude "Rate Limit Resets" row, read from the reset-grants response's `cedar_ember` block
/// (Anthropic's one-off usage-limit reset grants).
final class ClaudeResetGrantsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func resetsLine(_ json: String) throws -> MetricLine? {
        try ClaudeUsageMapper.mapResetGrantStatus(.json(json))?.line(now: now)
    }

    private func countAndExpiries(_ line: MetricLine?) -> (Double?, [Date])? {
        guard case .values(_, let values, let expiries) = line else { return nil }
        return (values.first?.number, expiries)
    }

    func testMapsEachRemainingResetWithItsGrantDeadline() throws {
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

    /// Robin's Max 20x login on Nov 10 (handoffs/SCO-150/claude-login-5): one Weekly grant Anthropic spends
    /// next, then three Fable launch grants that say `type: "full"`.
    private nonisolated static let maxLogin = """
    { "cedar_ember": { "eligible": true, "at_limit": false, "exhausted": [], "next_grant_id": "free_reset_oct_2026",
      "grants": [
        { "id": "free_reset_oct_2026", "label": "Free limit reset", "type": "weekly", "gives_back_weekly": false,
          "clears": ["seven_day", "seven_day_overage_included"], "resets_total": 1, "resets_left": 1,
          "ends_at": "2026-12-16T04:59:00+00:00", "paused": false, "usable_now": true, "use_requires_limit": false },
        { "id": "launch-2610-fable", "label": "New model launch: one Fable reset for Max, Team Premium and Enterprise Premium",
          "type": "full", "gives_back_weekly": true, "clears": ["seven_day_overage_included"], "resets_total": 1,
          "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "paused": false, "usable_now": true },
        { "id": "launch-2610-fable-12mo", "label": "New model launch: one more Fable reset at 12 months' tenure",
          "type": "full", "gives_back_weekly": true, "clears": ["seven_day_overage_included"], "resets_total": 1,
          "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "paused": false, "usable_now": true },
        { "id": "launch-2610-fable-6mo", "label": "New model launch: one more Fable reset at 6 months' tenure",
          "type": "full", "gives_back_weekly": true, "clears": ["seven_day_overage_included"], "resets_total": 1,
          "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "paused": false, "usable_now": true }
      ] } }
    """

    /// A Team login's Fable launch grant (claude-login-1): the session and Fable limits.
    private nonisolated static let teamFable = #"{ "id": "launch-2610-fable", "type": "full", "gives_back_weekly": true, "clears": ["five_hour", "seven_day_overage_included"], "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "usable_now": true }"#

    private func status(_ json: String) throws -> ClaudeResetGrantStatus {
        try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json(json)))
    }

    private func status(grants: [String]) throws -> ClaudeResetGrantStatus {
        try status(#"{"cedar_ember":{"eligible":true,"grants":[\#(grants.joined(separator: ","))]}}"#)
    }

    private func grant(_ fields: String) -> String {
        #"{"id":"g","resets_left":1,"ends_at":"2026-12-01T00:00:00+00:00","usable_now":true,\#(fields)}"#
    }

    func testKindComesFromTheGrantsFieldsAsClaudeCodeReadsThem() throws {
        let cases: [(String, ResetKind)] = [
            (#""type":"full","gives_back_weekly":true,"clears":["seven_day_overage_included"]"#, .fable),
            (#""type":"weekly","clears":["seven_day","seven_day_overage_included"]"#, .weekly),
            (#""type":"session","clears":["five_hour"]"#, .session),
            (#""type":"full","clears":["five_hour","seven_day"]"#, .full),
            (#""clears":["five_hour"]"#, .session),
            (#""clears":["seven_day"]"#, .weekly),
            (#""clears":["five_hour","seven_day"]"#, .full),
            (#""clears":[]"#, .full)
        ]
        for (fields, kind) in cases {
            XCTAssertEqual(try status(grants: [grant(fields)]).items(now: now).map(\.kind), [kind], fields)
        }
    }

    func testTheLabelNeverNamesTheKind() throws {
        let fields = #""label":"Fable reset","type":"weekly","gives_back_weekly":false,"clears":["seven_day"]"#
        XCTAssertEqual(try status(grants: [grant(fields)]).items(now: now).map(\.kind), [.weekly])
    }

    func testMaxLoginListsItsWeeklyResetThenThreeFableResetsEachClaimingItsOwnGrant() throws {
        let status = try status(Self.maxLogin)
        let items = status.items(now: now)
        XCTAssertEqual(items.map(\.kind), [.weekly, .fable, .fable, .fable])
        guard case .values(_, let values, _) = status.line(now: now) else { return XCTFail("expected the resets row") }
        XCTAssertEqual(values.first?.number, 4)

        let entries = RateLimitResetsDetail.content(count: 4, expiries: [], items: items, now: now).entries
        XCTAssertEqual(entries.compactMap(\.item?.kind.title), ["Weekly Reset", "Fable Reset", "Fable Reset", "Fable Reset"])
        XCTAssertEqual(entries.map(\.key.claim), [
            .claudeGrant("free_reset_oct_2026"), .claudeGrant("launch-2610-fable"),
            .claudeGrant("launch-2610-fable-12mo"), .claudeGrant("launch-2610-fable-6mo")
        ], "ties at one expiry keep a stable order by grant id")
        XCTAssertEqual(entries.map(\.number), [1, 2, 3, 4])
    }

    func testConfirmationSaysWhatEachLiveGrantRefills() throws {
        let max = try status(Self.maxLogin).items(now: now)
        XCTAssertEqual(max.first?.confirmDetail, "Refills your weekly and Fable limits now. This can't be undone.")
        XCTAssertEqual(max.last?.confirmDetail,
                       "Refills your Fable limit now and gives back what Fable used of your weekly limit. This can't be undone.")
        XCTAssertEqual(try status(grants: [Self.teamFable]).items(now: now).first?.confirmDetail,
                       "Refills your session and Fable limits now and gives back what Fable used of your weekly limit. This can't be undone.")
    }

    func testUnrecognizedWindowKeepsTheGeneralWording() throws {
        let item = try status(grants: [grant(#""clears":["five_hour","some_new_window"]"#)]).items(now: now).first
        XCTAssertNotNil(item)
        XCTAssertNil(item?.confirmDetail)
    }

    func testUseShowsOnlyOnAGrantAnthropicSaysCanBeUsedNow() throws {
        let unusable = #"{"id":"held","resets_left":1,"ends_at":"2026-12-01T00:00:00+00:00","usable_now":false}"#
        let paused = #"{"id":"paused","resets_left":1,"ends_at":"2026-12-02T00:00:00+00:00","usable_now":true,"paused":true}"#
        let items = try status(grants: [unusable, paused, grant(#""clears":["five_hour"]"#)]).items(now: now)
        XCTAssertEqual(items.map(\.claim), [.claudeGrant("held"), .claudeGrant("paused"), .claudeGrant("g")])
        XCTAssertEqual(items.map(\.usable), [false, false, true])
    }

    func testAnExpiredGrantLeavesTheList() throws {
        let lapsed = #"{"id":"lapsed","resets_left":1,"ends_at":"2026-09-01T00:00:00+00:00","usable_now":true}"#
        XCTAssertEqual(try status(grants: [lapsed, Self.teamFable]).items(now: now).map(\.claim), [.claudeGrant("launch-2610-fable")])
    }

    func testAGrantWithSeveralResetsListsARowForEachAndAClaimHereTakesOneOff() throws {
        let items = try status(grants: [#"{"id":"g","resets_left":2,"ends_at":"2026-12-01T00:00:00+00:00","usable_now":true}"#]).items(now: now)
        let entries = RateLimitResetsDetail.content(count: 2, expiries: [], items: items, now: now).entries
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
        let spent = RateLimitResetsDetail.content(count: 2, expiries: [], items: items, claimed: [.claudeGrant("g"): 1], now: now)
        XCTAssertEqual(spent.entries.count, 1)
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

    func testAGrantCountTooLargeForAnIntDropsTheBlock() {
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["id": "g", "resets_left": 1e300]]]))
    }

    func testAnUnreadableCheckThrows() {
        XCTAssertThrowsError(try resetsLine("not json")) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testResetGrantsRequestIdentifiesAsClaudeCode() async throws {
        // Anthropic gates reset grants by client surface: an unrecognized User-Agent comes back
        // `eligible: false, ineligible_reason: "surface"` with no grants.
        let http = RoutingHTTPClient { _ in .json("{}") }
        _ = try await ClaudeUsageClient(httpClient: http)
            .fetchResetGrants(accessToken: "token")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        let userAgent = try XCTUnwrap(request.headers["User-Agent"])
        XCTAssertTrue(userAgent.hasPrefix("claude-cli/"), userAgent)
        XCTAssertTrue(userAgent.hasSuffix("(external, cli)"), userAgent)
    }

    func testPopoverEntriesStayDistinctWhenResetsShareADeadline() {
        let deadline = now.addingTimeInterval(10 * 86_400)
        let entries = RateLimitResetsDetail.entries(from: [(deadline, nil), (deadline, nil)], now: now)
        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
    }
}
