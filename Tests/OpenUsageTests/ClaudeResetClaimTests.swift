import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeResetClaimTests: XCTestCase {
    private nonisolated static let orgUUID = "6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab"
    private nonisolated static let requestID = "11111111-2222-3333-4444-555555555555"
    private nonisolated static let grantID = "opus55-launch-promax-20260921"
    private nonisolated static let grantsBlock = """
        {"eligible":true,"at_limit":false,"grants":[{"id":"opus55-launch-promax-20260921","resets_left":1,
        "ends_at":"2099-10-22T16:00:00+00:00","clears":["five_hour","seven_day"],"paused":false,"usable_now":true,
        "use_requires_limit":false}],"next_grant_id":"opus55-launch-promax-20260921"}
        """

    func testClaimRequestMatchesClaudeCode() async throws {
        let http = RoutingHTTPClient { _ in .json("{}") }
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
        for reason in ["no_grant", "unknown_grant"] {
            XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"\#(reason)"}"#), .noCredit, reason)
        }
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"not_next_grant"}"#), .notNextReset(next: nil))
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

    func testClaimSpendsTheChosenGrantWithTheAccountsLoginAndUpdatesTheRowFromItsAnswer() async throws {
        let http = makeHTTP(claim: { _ in .json(#"{"result":"reset","resets_left":0,"cleared":["five_hour","seven_day"]}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)
        let service = try XCTUnwrap(runtime.resetClaimService { .refreshed })
        XCTAssertEqual(service.items.map(\.claim), [.claudeGrant(Self.grantID)])
        XCTAssertEqual(service.items.first?.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")
        let readsBefore = http.requests.count

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let sent = http.requests.dropFirst(readsBefore)
        XCTAssertEqual(sent.map(\.url.path), ["/api/organizations/\(Self.orgUUID)/reset_rate_limits"], "no grants or profile read")
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(try requestID(sent[sent.startIndex]), Self.requestID)
        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.items, [])
        let row = try XCTUnwrap(runtime.claude.session?.resetGrants.check?.status?.line(now: Date()))
        guard case .values(_, let values, _) = row else { return XCTFail("expected the resets row") }
        XCTAssertEqual(values.first?.number, 0)
    }

    func testAClaimAnswerWithACountTooLargeForAnIntSpendsOneReset() async throws {
        let http = makeHTTP(claim: { _ in .json(#"{"result":"reset","resets_left":1e300}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let row = try XCTUnwrap(runtime.claude.session?.resetGrants.check?.status?.line(now: Date()))
        guard case .values(_, let values, _) = row else { return XCTFail("expected the resets row") }
        XCTAssertEqual(values.first?.number, 0)
    }

    func testAClaimWithoutACachedOrganizationReadsTheProfileOnce() async throws {
        let http = makeHTTP(claim: { _ in .json(#"{"result":"reset","resets_left":0}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)
        runtime.claude.session?.organizationUUID = nil

        _ = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)
        _ = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "second-confirm")

        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 2, "the slot's read and one at claim time")
    }

    func testAClaimRefusedWithACutShortTokenRenewsTheSignInOnceAndRetries() async throws {
        let http = makeHTTP(claim: { request in
            request.headers["Authorization"] == "Bearer token-a"
                ? HTTPResponse(statusCode: 401, headers: [:], body: Data())
                : .json(#"{"result":"reset","resets_left":0}"#)
        })
        let (runtime, vault, account) = try makeRuntimeWithVault(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(claims.map { $0.headers["Authorization"] }, ["Bearer token-a", "Bearer token-b"])
        XCTAssertEqual(try claims.map(requestID), [Self.requestID, Self.requestID])
        XCTAssertEqual(http.requests.filter { $0.url.path == "/v1/oauth/token" }.count, 1)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("expected saved tokens") }
        XCTAssertEqual(saved.accessToken, "token-b")
    }

    func testScopeRefusedClaimSaysTheSignInCantUseResetsAndKeepsTheCheck() async throws {
        let refusal = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:inference"}}"#
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 403, headers: [:], body: Data(refusal.utf8)) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed(.notPermitted))
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }.count, 1)
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status)
        XCTAssertEqual(runtime.claude.session?.resetGrants.unsettledClaims, [:])
    }

    func testRemovedCredentialFailsWithoutSendingAClaim() async throws {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let (runtime, vault, account) = try makeRuntimeWithVault(http: http)
        await prime(runtime)
        try vault.delete(account.id)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed(.signInExpired))
    }

    func testRetryAfterAnUnsettledClaimReusesItsRequestID() async throws {
        let answer = TestSwitch("server down")
        let http = makeHTTP(claim: { _ in
            switch answer.value {
            case "server down": HTTPResponse(statusCode: 502, headers: [:], body: Data())
            case "throttled": HTTPResponse(statusCode: 429, headers: [:], body: Data())
            default: .json(#"{"result":"already_used"}"#)
            }
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let first = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "first-confirm")
        answer.value = "throttled"
        let refused = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "second-confirm")
        answer.value = "landed"
        let retry = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "reopened-popover")

        XCTAssertEqual(first, .failed(.refused))
        XCTAssertEqual(refused, .failed(.refused))
        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["first-confirm", "first-confirm", "first-confirm"])
        XCTAssertEqual(runtime.claude.session?.resetGrants.unsettledClaims, [:])
    }

    func testAnotherGrantsAnswerKeepsAnUnsettledClaimsRequestID() async throws {
        let lost = TestSwitch(true)
        let http = makeHTTP(grants: Self.maxLoginGrants, claim: { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
            if body["grant_id"] == "launch-2610-fable" {
                if lost.value { throw URLError(.networkConnectionLost) }
                return .json(#"{"result":"already_used"}"#)
            }
            return .json(#"{"result":"not_limited"}"#)
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        _ = await runtime.claimClaudeResetGrant("launch-2610-fable", redeemRequestID: "fable-first")
        _ = await runtime.claimClaudeResetGrant("free_reset_oct_2026", redeemRequestID: "weekly-request")
        lost.value = false
        let retry = await runtime.claimClaudeResetGrant("launch-2610-fable", redeemRequestID: "reopened-popover")

        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["fable-first", "weekly-request", "fable-first"])
    }

    func testLostAnswerReadsAsConnectionAndKeepsItsRequestID() async throws {
        let lost = TestSwitch(true)
        let http = makeHTTP(claim: { _ in
            if lost.value { throw URLError(.networkConnectionLost) }
            return .json(#"{"result":"already_used"}"#)
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let first = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "first-confirm")
        lost.value = false
        let retry = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "second-confirm")

        XCTAssertEqual(first, .failed(.connection))
        XCTAssertEqual(retry, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        XCTAssertEqual(try claims.map(requestID), ["first-confirm", "first-confirm"])
    }

    func testNoClaimWithoutAResetLeftOnTheChosenGrant() async throws {
        for grants in [
            #"{"eligible":false,"ineligible_reason":"tier","grants":[{"id":"g","resets_left":1}],"next_grant_id":"g"}"#,
            #"{"eligible":true,"grants":[{"id":"g","resets_left":0}],"next_grant_id":"g"}"#,
            #"{"eligible":true,"grants":[{"id":"other","resets_left":1}],"next_grant_id":"other"}"#
        ] {
            let http = makeHTTP(grants: grants, claim: { _ in
                XCTFail("must not claim")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
            let runtime = try makeRuntime(http: http)
            await prime(runtime)

            let outcome = await runtime.claimClaudeResetGrant("g", redeemRequestID: Self.requestID)
            XCTAssertEqual(outcome, .noCredit, grants)
        }
    }

    /// Robin's Max login: Anthropic lists the Weekly grant next, and the user picks a Fable row.
    private nonisolated static let maxLoginGrants = """
        {"eligible":true,"next_grant_id":"free_reset_oct_2026","grants":[
        {"id":"free_reset_oct_2026","type":"weekly","clears":["seven_day","seven_day_overage_included"],"resets_left":1,
         "ends_at":"2099-12-16T04:59:00+00:00","usable_now":true},
        {"id":"launch-2610-fable","type":"full","gives_back_weekly":true,"clears":["seven_day_overage_included"],
         "resets_left":1,"ends_at":"2100-03-09T07:59:00+00:00","usable_now":true},
        {"id":"launch-2610-fable-6mo","type":"full","gives_back_weekly":true,"clears":["seven_day_overage_included"],
         "resets_left":1,"ends_at":"2100-03-09T07:59:00+00:00","usable_now":true}]}
        """

    func testUseOnAFableRowClaimsThatRowsGrantNotTheNextOne() async throws {
        let http = makeHTTP(grants: Self.maxLoginGrants, claim: { _ in .json(#"{"result":"reset","resets_left":0}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)
        let service = try XCTUnwrap(runtime.resetClaimService { .refreshed })
        let row2 = try XCTUnwrap(RateLimitResetsDetail.content(count: 3, expiries: [], items: service.items).entries.dropFirst().first?.item)
        XCTAssertEqual(row2.kind, .fable)

        let outcome = await service.claim(row2, requestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let claims = http.requests.filter { $0.url.path.hasSuffix("/reset_rate_limits") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(claims.first?.body)) as? [String: String])
        XCTAssertEqual(payload["grant_id"], "launch-2610-fable")
        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.items.map(\.claim),
                       [.claudeGrant("free_reset_oct_2026"), .claudeGrant("launch-2610-fable-6mo")])
    }

    func testARefusalToSpendAResetBeforeTheNextOneNamesTheResetToUseFirst() async throws {
        let http = makeHTTP(grants: Self.maxLoginGrants, claim: { _ in .json(#"{"result":"unavailable","reason":"not_next_grant"}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant("launch-2610-fable", redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .notNextReset(next: .weekly))
        XCTAssertEqual(outcome.message(), "Claude wants your Weekly Reset used first. Nothing was used.")
        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.items.count, 3, "nothing was spent")
        XCTAssertEqual(runtime.claude.session?.resetGrants.unsettledClaims, [:])
    }

    func testMalformedRequestIDIsRefusedBeforeSending() async throws {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: "not a valid id!")
        XCTAssertEqual(outcome, .failed(.refused))
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check)
    }

    func testRefusedClaimKeepsTheCheck() async throws {
        let http = makeHTTP(claim: { _ in .json(#"{"result":"not_limited","reason":null}"#) })
        let runtime = try makeRuntime(http: http)
        await prime(runtime)

        let outcome = await runtime.claimClaudeResetGrant(Self.grantID, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertNotNil(runtime.claude.session?.resetGrants.check?.status, "a refused claim changed nothing, so the hourly check stands")
    }

    private func makeHTTP(
        grants: String = grantsBlock,
        claim: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.isClaudeResetGrantsCheck
                    ? .json(#"{"cedar_ember":\#(grants)}"#)
                    : .json(#"{"five_hour":{"utilization":100,"resets_at":"2099-01-01T00:00:00.000Z"}}"#)
            case "/api/oauth/profile":
                return .json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"\#(Self.orgUUID)","organization_type":"claude_max"}}"#)
            case "/v1/oauth/token":
                return .json(#"{"access_token":"token-b","refresh_token":"refresh-b","expires_in":3600}"#)
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
}
