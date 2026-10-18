import XCTest
@testable import OpenUsage

/// Claiming a Claude reset grant: request shape, outcome decoding, and the provider's full flow, all
/// through a stub HTTP client. The real endpoint is never touched (see the env-gated dry run below).
@MainActor
final class ClaudeResetClaimTests: XCTestCase {
    private nonisolated static let start = OpenUsageISO8601.date(from: "2026-10-18T12:00:00.000Z")!
    private nonisolated static let orgUUID = "6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab"
    private nonisolated static let requestID = "11111111-2222-3333-4444-555555555555"
    private nonisolated static let fileCredentials =
        #"{"claudeAiOauth":{"accessToken":"token-a","refreshToken":"refresh-a","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#
    private nonisolated static let config = ClaudeOAuthConfig(
        usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        refreshURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: "client"
    )
    private nonisolated static let grantsBlock = """
        {"eligible":true,"at_limit":false,"grants":[{"id":"opus55-launch-promax-20260921","resets_left":1,
        "ends_at":"2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day"],"paused":false,"usable_now":true,
        "use_requires_limit":false}],"next_grant_id":"opus55-launch-promax-20260921"}
        """

    // MARK: - Request shape

    func testClaimRequestMatchesClaudeCode() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        _ = try await ClaudeUsageClient(httpClient: http).claimResetGrant(
            accessToken: "token-a", organizationUUID: Self.orgUUID,
            grantID: "opus55-launch-promax-20260921", requestID: Self.requestID, config: Self.config
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/api/organizations/\(Self.orgUUID)/reset_rate_limits")
        XCTAssertEqual(request.timeout, 25)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(request.headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["User-Agent"], "claude-cli/2.1.294 (external, cli)")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(payload, [
            "program": "cedar_ember", "grant_id": "opus55-launch-promax-20260921", "request_id": Self.requestID
        ])
    }

    // MARK: - Outcome decoding

    func testOutcomeTable() {
        func outcome(_ json: String, status: Int = 200) -> ResetClaimOutcome {
            ClaudeProvider.resetClaimOutcome(from: HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8)))
        }
        let cooldown = OpenUsageISO8601.date(from: "2026-10-18T13:00:00Z")!
        XCTAssertEqual(outcome(#"{"result":"reset","resets_left":0,"cleared":["five_hour","seven_day"]}"#), .success)
        XCTAssertEqual(outcome(#"{"result":"already_used"}"#), .success)
        XCTAssertEqual(outcome(#"{"result":"not_limited"}"#), .nothingToReset)
        XCTAssertEqual(outcome(#"{"result":"ineligible","reason":"tier"}"#), .noCredit)
        for reason in ["no_grant", "unknown_grant", "not_next_grant"] {
            XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"\#(reason)"}"#), .noCredit, reason)
        }
        XCTAssertEqual(outcome(#"{"result":"reset_unconfirmed"}"#), .unconfirmed)
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"stamp_indeterminate"}"#), .unconfirmed)
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":"2026-10-18T13:00:00Z"}"#), .unavailableNow(until: cooldown))
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"paused"}"#), .unavailableNow(until: nil))
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"low_priority_active"}"#), .unavailableNow(until: nil))
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"not_authorized"}"#), .failed)
        XCTAssertEqual(outcome(#"{"result":"something_new"}"#), .failed)
        XCTAssertEqual(outcome("not json"), .failed)
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 429), .failed)
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 500), .failed)
    }

    // MARK: - Status parse

    func testStatusParseRejectsBlockWithMalformedGrant() {
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["resets_left": 1]]]))
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["id": "g"]]]))
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": ["g"]]))
        XCTAssertNotNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["id": "g", "resets_left": 1]]]))
    }

    func testClaimableGrantAndConfirmCopy() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.grantsBlock.utf8)) as? [String: Any])
        let status = try XCTUnwrap(ClaudeResetGrantStatus.parse(body))
        XCTAssertEqual(status.claimableGrantID, "opus55-launch-promax-20260921")
        XCTAssertEqual(status.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")

        var ineligible = status
        ineligible.eligible = false
        XCTAssertNil(ineligible.claimableGrantID)
        var noNext = status
        noNext.nextGrantID = nil
        XCTAssertNil(noNext.claimableGrantID)
    }

    // MARK: - Provider flow

    func testClaimSpendsNextGrantThenRereadsGrants() async throws {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset","resets_left":0}"#) })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()
        let service = ClaudeResetClaimService(provider: provider)
        XCTAssertTrue(service.isClaimable)

        let outcome = await service.claim(creditExpiringAt: Self.start, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let claims = http.requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(claims.map(\.url.path), ["/api/organizations/\(Self.orgUUID)/reset_rate_limits"])
        XCTAssertEqual(try requestID(claims[0]), Self.requestID)
        XCTAssertNil(provider.resetGrantsCheck)
        XCTAssertFalse(service.isClaimable)
    }

    func testAuthRejectionNeverFallsBackToAnotherLogin() async throws {
        let keychainCredentials = Self.fileCredentials.replacingOccurrences(of: "token-a", with: "token-k")
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) })
        let provider = makeProvider(http: http, keychain: FakeKeychain(keychainCredentials))
        _ = await provider.refresh()
        let grantsLogin = try XCTUnwrap(http.requests.last { $0.isClaudeResetGrantsCheck }?.headers["Authorization"])

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(claims.map { $0.headers["Authorization"] }, [grantsLogin])
    }

    func testRetryAfterAnUnsettledClaimReusesItsRequestID() async throws {
        let serverDown = RateLimitSwitch()
        let throttled = RateLimitSwitch()
        serverDown.on = true
        let http = makeHTTP(claim: { _ in
            if serverDown.on { return HTTPResponse(statusCode: 502, headers: [:], body: Data()) }
            if throttled.on { return HTTPResponse(statusCode: 429, headers: [:], body: Data()) }
            return Self.json(#"{"result":"already_used"}"#)
        })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()

        let first = await provider.claimResetGrant(redeemRequestID: "first-confirm")
        serverDown.on = false
        throttled.on = true
        let refused = await provider.claimResetGrant(redeemRequestID: "second-confirm")
        throttled.on = false
        let retry = await provider.claimResetGrant(redeemRequestID: "reopened-popover")

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(refused, .failed)
        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["first-confirm", "first-confirm", "first-confirm"])
        XCTAssertNil(provider.unsettledResetClaim)
    }

    func testClaimLiftsTheRateLimitCooldown() async {
        let usage = RateLimitSwitch()
        let http = makeHTTP(rateLimited: usage, claim: { _ in Self.json(#"{"result":"reset"}"#) })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()
        usage.on = true
        _ = await provider.refresh()
        let beforeClaim = http.requests.count

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)
        usage.on = false
        _ = await provider.refresh()

        XCTAssertEqual(outcome, .success)
        let afterClaim = http.requests.dropFirst(beforeClaim)
        XCTAssertTrue(
            afterClaim.contains { $0.url.path == "/api/oauth/usage" && !$0.isClaudeResetGrantsCheck },
            "the post-claim refresh must fetch live usage instead of serving the pre-claim cache"
        )
    }

    func testNoClaimWithoutAClaimableGrant() async {
        let http = makeHTTP(grants: #"{"eligible":false,"ineligible_reason":"tier","grants":[]}"#, claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()

        XCTAssertFalse(ClaudeResetClaimService(provider: provider).isClaimable)
        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)
        XCTAssertEqual(outcome, .noCredit)
    }

    func testMalformedRequestIDIsRefusedBeforeSending() async {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()

        let outcome = await provider.claimResetGrant(redeemRequestID: "not a valid id!")
        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(provider.resetGrantsCheck)
    }

    func testRefusedClaimKeepsTheCache() async {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"not_limited","reason":null}"#) })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertNotNil(provider.resetGrantsCheck?.status, "a refused claim changed nothing, so the hourly check stands")
    }

    func testFailedClaimKeepsTheGrantsCheck() async {
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data("oops".utf8)) })
        let provider = makeProvider(http: http)
        _ = await provider.refresh()

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)
        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(provider.resetGrantsCheck?.status)
    }

    // MARK: - Live dry run (never runs by default)

    /// Sends our real claim request with a grant id that matches no grant, so nothing can be spent. The
    /// expected answer is HTTP 200 `unavailable`/`unknown_grant`. Opt in with
    /// OPENUSAGE_LIVE_CLAUDE_CLAIM_DRYRUN=1.
    func testLiveDryRunWithUnknownGrant() async throws {
        guard ProcessInfo.processInfo.environment["OPENUSAGE_LIVE_CLAUDE_CLAIM_DRYRUN"] == "1" else {
            throw XCTSkip("live dry run is opt-in (OPENUSAGE_LIVE_CLAUDE_CLAIM_DRYRUN=1)")
        }
        let authStore = ClaudeAuthStore()
        let client = ClaudeUsageClient()
        let state = try XCTUnwrap(authStore.loadCredentialSet().candidates.first {
            $0.hasUsableAccessToken && authStore.liveUsageAvailability($0) == .available
        }, "no usable Claude login")
        if authStore.needsRefresh(state.oauth) { throw XCTSkip("token needs a refresh; open Claude Code first") }
        let token = try XCTUnwrap(state.oauth.accessToken)
        let config = try authStore.oauthConfig()
        let profile = try ClaudeUsageClient.decodeProfile(try await client.fetchProfile(accessToken: token, config: config))
        let org = try XCTUnwrap(profile.organization?.uuid)

        let response = try await client.claimResetGrant(
            accessToken: token, organizationUUID: org, grantID: "openusage-dryrun-probe",
            requestID: UUID().uuidString, config: config
        )
        print("dry-run claim response (\(response.statusCode)): \(String(decoding: response.body, as: UTF8.self))")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeProvider.resetClaimOutcome(from: response), .noCredit)
    }

    // MARK: - Helpers

    private func makeHTTP(
        grants: String = grantsBlock,
        rateLimited: RateLimitSwitch = RateLimitSwitch(),
        claim: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage" where rateLimited.on:
                return HTTPResponse(statusCode: 429, headers: ["Retry-After": "3600"], body: Data())
            case "/api/oauth/usage":
                return request.isClaudeResetGrantsCheck
                    ? Self.json(#"{"cedar_ember":\#(grants)}"#)
                    : Self.json(#"{"five_hour":{"utilization":100,"resets_at":"2099-01-01T00:00:00.000Z"}}"#)
            case "/api/oauth/profile":
                return Self.json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"\#(Self.orgUUID)","organization_type":"claude_max"}}"#)
            case "/api/organizations/\(Self.orgUUID)/reset_rate_limits":
                return claim(request)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
    }

    private func makeProvider(http: RoutingHTTPClient, keychain: FakeKeychain = FakeKeychain()) -> ClaudeProvider {
        let clock = TestClock(Self.start)
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: FakeFiles(["/tmp/claude/.credentials.json": Self.fileCredentials]),
            keychain: keychain,
            now: { clock.now }
        )
        return ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )
    }

    private func requestID(_ request: HTTPRequest) throws -> String? {
        let body = try XCTUnwrap(request.body)
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["request_id"] as? String
    }

    private nonisolated static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(text.utf8))
    }
}

/// Makes the mock usage endpoint answer 429 while `on`.
private final class RateLimitSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
