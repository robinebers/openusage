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

    /// The live shape of the Fable launch grants: the session and Fable limits, with the week's Fable use
    /// taken off the weekly limit.
    private func fableStatus(clears: String = #"["five_hour","seven_day_overage_included"]"#,
                             otherGrant: String = "") throws -> ClaudeResetGrantStatus {
        try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json("""
        { "cedar_ember": { "eligible": true, "grants": [
            { "id": "launch-2610-fable", "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00",
              "label": "New model launch: one Fable reset for Max, Team Premium and Enterprise Premium",
              "clears": \(clears), "gives_back_weekly": true },
            { "id": "launch-2610-fable-6mo", "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00",
              "label": "New model launch: one more Fable reset at 6 months' tenure",
              "clears": \(clears), "gives_back_weekly": true }\(otherGrant)
          ], "next_grant_id": "launch-2610-fable" } }
        """)))
    }

    func testFableGrantNamesItsLimitsAndTheWeeklyGiveBack() throws {
        let status = try fableStatus()
        XCTAssertEqual(
            status.confirmDetail,
            "Refills your session and Fable limits now, and takes this week's Fable use off your weekly limit. This can't be undone."
        )
        let expiry = try XCTUnwrap(OpenUsageISO8601.date(from: "2027-03-09T07:59:00+00:00"))
        XCTAssertEqual(status.sections(now: now), [ResetSection(title: "Fable", expiries: [expiry, expiry], usable: true)])
    }

    func testUnrecognizedWindowKeepsTheGeneralWording() throws {
        XCTAssertNil(try fableStatus(clears: #"["five_hour","some_new_window"]"#).confirmDetail)
    }

    func testMixedGrantsListEachKindApartAndOnlyTheNextCanBeSpent() throws {
        let other = #", { "id": "other", "resets_left": 2, "ends_at": "2026-12-01T00:00:00+00:00", "clears": ["five_hour", "seven_day"] }"#
        let sections = try fableStatus(otherGrant: other).sections(now: now)
        let ordinary = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-12-01T00:00:00+00:00"))
        XCTAssertEqual(sections.map(\.title), ["Fable", "Session & Weekly"])
        XCTAssertEqual(sections.map(\.usable), [true, false])
        XCTAssertEqual(sections.last?.expiries, [ordinary, ordinary])
    }

    func testExpiredOrdinaryGrantLeavesOnlyTheFableSection() throws {
        let lapsed = #", { "id": "lapsed", "resets_left": 1, "ends_at": "2026-09-01T00:00:00+00:00", "clears": ["five_hour", "seven_day"] }"#
        XCTAssertEqual(try fableStatus(otherGrant: lapsed).sections(now: now).map(\.title), ["Fable"])
    }

    func testUnrecognizedWindowIsNotTitledByTheWindowsItShares() throws {
        let status = try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json(
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":1,"ends_at":"2026-12-01T00:00:00+00:00","clears":["five_hour","seven_day_overage_included"]}],"next_grant_id":"g"}}"#
        )))
        XCTAssertEqual(status.sections(now: now).map(\.title), ["Other"])
    }

    func testNextGrantOutsideTheSectionsLeavesThemUsable() throws {
        let lapsedNext = #", { "id": "lapsed", "resets_left": 1, "ends_at": "2026-09-01T00:00:00+00:00", "clears": ["five_hour", "seven_day"] }"#
        let status = try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json("""
        { "cedar_ember": { "eligible": true, "grants": [
            { "id": "launch-2610-fable", "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00",
              "clears": ["five_hour","seven_day_overage_included"] }\(lapsedNext)
          ], "next_grant_id": "lapsed" } }
        """)))
        XCTAssertEqual(status.sections(now: now).map(\.usable), [true])
        XCTAssertEqual(status.sections(now: now).map(\.holdsNextReset), [false])
    }

    func testAClaimOnAnUnlistedNextGrantTakesNoRowFromEitherSection() throws {
        let shared = "2027-03-09T07:59:00+00:00"
        let status = try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json("""
        { "cedar_ember": { "eligible": true, "grants": [
            { "id": "lapsed", "resets_left": 1, "ends_at": "2026-09-01T00:00:00+00:00", "clears": ["five_hour", "seven_day"] },
            { "id": "launch-2610-fable", "resets_left": 1, "ends_at": "\(shared)", "clears": ["five_hour","seven_day_overage_included"] },
            { "id": "other", "resets_left": 1, "ends_at": "\(shared)", "clears": ["five_hour", "seven_day"] }
          ], "next_grant_id": "lapsed" } }
        """)))
        let sections = status.sections(now: now)
        XCTAssertEqual(sections.map(\.usable), [true, true])
        let expiry = try XCTUnwrap(OpenUsageISO8601.date(from: shared))
        let groups = RateLimitResetsDetail.sectionGroups(sections, claimed: [expiry: 1], now: now)
        XCTAssertEqual(groups.map(\.title), ["Fable", "Session & Weekly"])
        XCTAssertEqual(groups.map(\.entries.count), [1, 1])
    }

    func testNextGrantWithoutADeadlineLeavesTheListedSectionUsable() throws {
        let status = try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json("""
        { "cedar_ember": { "eligible": true, "grants": [
            { "id": "undated", "resets_left": 1, "ends_at": null, "clears": ["five_hour", "seven_day"] },
            { "id": "launch-2610-fable", "resets_left": 1, "ends_at": "2027-03-09T07:59:00+00:00", "clears": ["five_hour","seven_day_overage_included"] }
          ], "next_grant_id": "undated" } }
        """)))
        let groups = RateLimitResetsDetail.sectionGroups(status.sections(now: now), claimed: [:], now: now)
        XCTAssertEqual(groups.map(\.title), ["Fable"])
        let fable = try XCTUnwrap(status.sections(now: now).first { $0.title == "Fable" })
        XCTAssertTrue(fable.usable)
        XCTAssertFalse(fable.holdsNextReset)
        XCTAssertEqual(status.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")
    }

    func testOrdinaryGrantsAloneStillGetTheirTitle() throws {
        let status = try XCTUnwrap(ClaudeUsageMapper.mapResetGrantStatus(.json(
            #"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":1,"ends_at":"2026-12-01T00:00:00+00:00","clears":["five_hour","seven_day"]}],"next_grant_id":"g"}}"#
        )))
        let expiry = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-12-01T00:00:00+00:00"))
        XCTAssertEqual(status.sections(now: now), [ResetSection(title: "Session & Weekly", expiries: [expiry], usable: true)])
    }

    func testSectionsSharingAnExpiryKeepTheirRowsApartAndSpendFromTheUsableOne() {
        let expiry = now.addingTimeInterval(86_400)
        let sections = [
            ResetSection(title: "Fable", expiries: [expiry, expiry], usable: true),
            ResetSection(title: "Session & Weekly", expiries: [expiry], usable: false)
        ]
        let groups = RateLimitResetsDetail.sectionGroups(sections, claimed: [:], now: now)
        XCTAssertEqual(Set(groups.flatMap(\.entries).map(\.key)).count, 3)
        let spent = RateLimitResetsDetail.sectionGroups(sections, claimed: [expiry: 1], now: now)
        XCTAssertEqual(spent.map(\.entries.count), [1, 1])
        let gone = RateLimitResetsDetail.sectionGroups(sections, claimed: [expiry: 2], now: now)
        XCTAssertEqual(gone.map(\.title), ["Session & Weekly"])
    }

    func testConfirmationDoesNotSurviveASwitchBetweenOneTimelineAndSections() throws {
        let ordinary = now.addingTimeInterval(86_400)
        let fable = now.addingTimeInterval(2 * 86_400)
        let flatKey = try XCTUnwrap(RateLimitResetsDetail.entries(from: [ordinary], now: now).first?.key)
        let sections = [
            ResetSection(title: "Session & Weekly", expiries: [ordinary], usable: true),
            ResetSection(title: "Fable", expiries: [fable], usable: false)
        ]
        XCTAssertTrue(RateLimitResetsDetail.timelineKeys(expiries: [ordinary], sections: [], now: now).contains(flatKey))
        let grouped = RateLimitResetsDetail.timelineKeys(expiries: [ordinary, fable], sections: sections, now: now)
        XCTAssertFalse(grouped.contains(flatKey), "the ordinary expiry is still there, but under a section's row")
        let sectionKey = try XCTUnwrap(grouped.first { $0.date == ordinary })
        XCTAssertFalse(RateLimitResetsDetail.timelineKeys(expiries: [ordinary], sections: [], now: now).contains(sectionKey))
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
        let entries = RateLimitResetsDetail.entries(from: [deadline, deadline], now: now)
        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
    }
}
