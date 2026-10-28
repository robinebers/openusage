import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeResetClaimTests: XCTestCase {
    private nonisolated static let orgUUID = "6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab"
    private nonisolated static let requestID = "11111111-2222-3333-4444-555555555555"
    private nonisolated static let grantsBlock = """
        {"eligible":true,"at_limit":false,"grants":[{"id":"opus55-launch-promax-20260921","resets_left":1,
        "ends_at":"2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day"],"paused":false,"usable_now":true,
        "use_requires_limit":false}],"next_grant_id":"opus55-launch-promax-20260921"}
        """

    func testClaimRequestMatchesClaudeCode() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        _ = try await ClaudeUsageClient(httpClient: http).claimResetGrant(
            accessToken: "token-a", organizationUUID: Self.orgUUID,
            grantID: "opus55-launch-promax-20260921", requestID: Self.requestID
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

    func testOutcomeTable() {
        func outcome(_ json: String, status: Int = 200) -> ResetClaimOutcome {
            ClaudeUsageMapper.resetClaimOutcome(from: HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8)))
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
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"not_authorized"}"#), .failed(.refused))
        XCTAssertEqual(outcome(#"{"result":"something_new"}"#), .failed(.refused))
        XCTAssertEqual(outcome("not json"), .failed(.refused))
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 429), .failed(.refused))
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 500), .failed(.refused))
        XCTAssertEqual(outcome("", status: 401), .failed(.signInExpired))
        XCTAssertEqual(outcome("", status: 403), .failed(.signInExpired))
        let scopeRefusal = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:inference"}}"#
        XCTAssertEqual(outcome(scopeRefusal, status: 403), .failed(.notPermitted))
    }

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

    func testClaimSpendsNextGrantWithTheAccountsLoginAndUpdatesTheRowFromItsAnswer() async throws {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset","resets_left":0,"cleared":["five_hour","seven_day"]}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)
        let service = try XCTUnwrap(runtime.resetClaimService { .refreshed })
        XCTAssertTrue(service.isClaimable)
        XCTAssertEqual(service.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")
        let readsBefore = http.requests.count

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let sent = http.requests.dropFirst(readsBefore)
        XCTAssertEqual(sent.map(\.url.path), ["/api/organizations/\(Self.orgUUID)/reset_rate_limits"], "no grants or profile read")
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(try requestID(sent[sent.startIndex]), Self.requestID)
        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.isClaimable, false)
        let row = try XCTUnwrap(runtime.claude.session?.resetGrants.check?.status?.line(now: Date()))
        guard case .values(_, let values, _) = row else { return XCTFail("expected the resets row") }
        XCTAssertEqual(values.first?.number, 0)
    }

    func testAClaimWithoutACachedOrganizationReadsTheProfileOnce() async throws {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset","resets_left":0}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)
        runtime.claude.session?.organizationUUID = nil

        _ = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)
        _ = await runtime.claimClaudeResetGrant(redeemRequestID: "second-confirm")

        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 2, "the slot's read and one at claim time")
    }

    func testClaimRefreshesAnExpiredTokenAndSavesItFirst() async throws {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset"}"#) })
        let (runtime, vault, account) = try makeRuntimeWithVault(http: http)
        await prime(runtime)
        try vault.save(
            .oauth(OAuthTokens(accessToken: "token-a", refreshToken: "refresh-a", expiresAt: .distantPast)),
            for: account.id
        )

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let claim = try XCTUnwrap(http.requests.last { $0.url.path.hasSuffix("/reset_rate_limits") })
        XCTAssertEqual(claim.headers["Authorization"], "Bearer token-b")
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("expected saved tokens") }
        XCTAssertEqual(saved.accessToken, "token-b")
    }

    func testRejectedClaimReadsAsExpiredSignInAndKeepsTheCheck() async throws {
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed(.signInExpired))
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(claims.map { $0.headers["Authorization"] }, ["Bearer token-a"])
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status)
    }

    func testScopeRefusedClaimSaysTheSignInCantUseResetsAndKeepsTheCheck() async throws {
        let refusal = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:inference"}}"#
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 403, headers: [:], body: Data(refusal.utf8)) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed(.notPermitted))
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }.count, 1)
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status)
        XCTAssertNil(runtime.claude.session?.resetGrants.unsettledClaim)
    }

    func testRemovedCredentialFailsWithoutSendingAClaim() async throws {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let (runtime, vault, account) = try makeRuntimeWithVault(http: http)
        await prime(runtime)
        try vault.delete(account.id)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed(.signInExpired))
    }

    func testRetryAfterAnUnsettledClaimReusesItsRequestID() async throws {
        let answer = TestSwitch("server down")
        let http = makeHTTP(claim: { _ in
            switch answer.value {
            case "server down": HTTPResponse(statusCode: 502, headers: [:], body: Data())
            case "throttled": HTTPResponse(statusCode: 429, headers: [:], body: Data())
            default: Self.json(#"{"result":"already_used"}"#)
            }
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let first = await runtime.claimClaudeResetGrant(redeemRequestID: "first-confirm")
        answer.value = "throttled"
        let refused = await runtime.claimClaudeResetGrant(redeemRequestID: "second-confirm")
        answer.value = "landed"
        let retry = await runtime.claimClaudeResetGrant(redeemRequestID: "reopened-popover")

        XCTAssertEqual(first, .failed(.refused))
        XCTAssertEqual(refused, .failed(.refused))
        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["first-confirm", "first-confirm", "first-confirm"])
        XCTAssertNil(runtime.claude.session?.resetGrants.unsettledClaim)
    }

    func testLostAnswerReadsAsConnectionAndKeepsItsRequestID() async throws {
        let lost = TestSwitch(true)
        let http = makeHTTP(claim: { _ in
            if lost.value { throw URLError(.networkConnectionLost) }
            return Self.json(#"{"result":"already_used"}"#)
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let first = await runtime.claimClaudeResetGrant(redeemRequestID: "first-confirm")
        lost.value = false
        let retry = await runtime.claimClaudeResetGrant(redeemRequestID: "second-confirm")

        XCTAssertEqual(first, .failed(.connection))
        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["first-confirm", "first-confirm"])
    }

    func testNoClaimWithoutAClaimableGrant() async throws {
        let http = makeHTTP(grants: #"{"eligible":false,"ineligible_reason":"tier","grants":[]}"#, claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.isClaimable, false)
        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)
        XCTAssertEqual(outcome, .noCredit)
    }

    func testMalformedRequestIDIsRefusedBeforeSending() async throws {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: "not a valid id!")
        XCTAssertEqual(outcome, .failed(.refused))
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check)
    }

    func testRefusedClaimKeepsTheCheck() async throws {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"not_limited","reason":null}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status, "a refused claim changed nothing, so the hourly check stands")
    }

    func testFailedClaimKeepsTheCheck() async throws {
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data("oops".utf8)) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(redeemRequestID: Self.requestID)
        XCTAssertEqual(outcome, .failed(.refused))
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status)
    }

    private func makeHTTP(
        grants: String = grantsBlock,
        claim: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.isClaudeResetGrantsCheck
                    ? Self.json(#"{"cedar_ember":\#(grants)}"#)
                    : Self.json(#"{"five_hour":{"utilization":100,"resets_at":"2099-01-01T00:00:00.000Z"}}"#)
            case "/api/oauth/profile":
                return Self.json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"\#(Self.orgUUID)","organization_type":"claude_max"}}"#)
            case "/v1/oauth/token":
                return Self.json(#"{"access_token":"token-b","refresh_token":"refresh-b","expires_in":3600}"#)
            case "/api/organizations/\(Self.orgUUID)/reset_rate_limits":
                return try claim(request)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
    }

    private func prime(_ runtime: AccountProviderRuntime) async {
        guard case .success(let snapshot) = await runtime.refresh() else { return XCTFail("the priming refresh failed") }
        _ = await runtime.refreshHourlyReads(of: snapshot)
    }

    private func makeRuntime(http: RoutingHTTPClient) throws -> AccountProviderRuntime {
        try makeRuntimeWithVault(http: http).runtime
    }

    private func makeRuntimeWithVault(
        http: RoutingHTTPClient
    ) throws -> (runtime: AccountProviderRuntime, vault: InMemoryCredentialVault, account: Account) {
        let account = Account(kind: .claude, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token-a", refreshToken: "refresh-a")), for: account.id)
        return (AccountProviderRuntime(account: account, vault: vault, http: http), vault, account)
    }

    private func requestID(_ request: HTTPRequest) throws -> String? {
        let body = try XCTUnwrap(request.body)
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["request_id"] as? String
    }

    private nonisolated static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(text.utf8))
    }
}
