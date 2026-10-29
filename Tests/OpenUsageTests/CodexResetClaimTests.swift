import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private nonisolated static func listBody(expiry: Date = expiry, status: String = "available") -> Data {
        Data("""
        {"credits": [
            {"id": "RateLimitResetCredit_other", "status": "available",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry.addingTimeInterval(999_999)))"},
            {"id": "RateLimitResetCredit_target", "status": "\(status)",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry))"}
        ], "available_count": 2}
        """.utf8)
    }

    private nonisolated static func consumeBody(code: String) -> Data {
        Data(#"{"code": "\#(code)", "windows_reset": 2}"#.utf8)
    }

    func testConsumeRequestShape() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
        }
        _ = try await CodexUsageClient(http: http).consumeResetCredit(
            accessToken: "token-123", accountID: "acct-456",
            creditID: "RateLimitResetCredit_target", redeemRequestID: "11111111-2222-3333-4444-555555555555"
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CodexUsageClient.consumeResetCreditURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-123")
        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acct-456")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(payload, [
            "redeem_request_id": "11111111-2222-3333-4444-555555555555",
            "credit_id": "RateLimitResetCredit_target"
        ])
    }

    func testConsumeOutcomeDecodesAllProtocolCodes() {
        func outcome(_ code: String, status: Int = 200) -> ResetClaimOutcome {
            CodexUsageMapper.resetClaimOutcome(from: HTTPResponse(statusCode: status, headers: [:], body: Self.consumeBody(code: code)))
        }
        XCTAssertEqual(outcome("reset"), .success)
        // The idempotency key already spent this credit on a lost-response retry, so it's still a success.
        XCTAssertEqual(outcome("already_redeemed"), .success)
        XCTAssertEqual(outcome("nothing_to_reset"), .nothingToReset)
        XCTAssertEqual(outcome("no_credit"), .noCredit)
        XCTAssertEqual(outcome("something_new"), .failed(.refused))
        XCTAssertEqual(outcome("reset", status: 500), .failed(.refused))
        XCTAssertEqual(outcome("reset", status: 401), .failed(.signInExpired))
        XCTAssertEqual(
            CodexUsageMapper.resetClaimOutcome(from: HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))),
            .failed(.refused)
        )
    }

    func testCreditMatchingByExpiry() throws {
        let body = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody()))
        XCTAssertEqual(CodexUsageMapper.resetCreditID(in: body, expiringAt: Self.expiry), "RateLimitResetCredit_target")
        XCTAssertEqual(
            CodexUsageMapper.resetCreditID(in: body, expiringAt: Self.expiry.addingTimeInterval(0.5)),
            "RateLimitResetCredit_target"
        )
        XCTAssertNil(CodexUsageMapper.resetCreditID(in: body, expiringAt: Self.expiry.addingTimeInterval(3600)))
    }

    func testCreditMatchingSkipsNonAvailableStatusButKeepsMissingStatus() throws {
        let redeemed = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody(status: "redeemed")))
        XCTAssertNil(CodexUsageMapper.resetCreditID(in: redeemed, expiringAt: Self.expiry))

        let noStatus = try XCTUnwrap(ProviderParse.jsonObject(Data(
            #"{"credits": [{"id": "RateLimitResetCredit_bare", "expires_at": \#(Self.expiry.timeIntervalSince1970)}]}"#.utf8
        )))
        XCTAssertEqual(CodexUsageMapper.resetCreditID(in: noStatus, expiringAt: Self.expiry), "RateLimitResetCredit_bare")
    }

    func testClaimMatchesCreditAndConsumesItWithTheAccountsLogin() async throws {
        let http = makeHTTP()
        let runtime = try makeRuntime(http: http)

        let outcome = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL])
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer token-123", "Bearer token-123"])
        XCTAssertEqual(http.requests.map { $0.headers["ChatGPT-Account-Id"] }, ["acct-456", "acct-456"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.requests.last?.body)) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the freshly matched id, by expiry")
        XCTAssertEqual(payload["redeem_request_id"], "redeem-1", "the caller's idempotency key, verbatim")
    }

    func testAClaimRefusedWithACutShortTokenRenewsTheSignInOnceAndRetries() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexLogin.tokenURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"token-new","refresh_token":"refresh-new"}"#.utf8))
            case _ where request.headers["Authorization"] == "Bearer token-123":
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            default:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
            }
        }
        let runtime = try makeRuntime(http: http, credential: .oauth(OAuthTokens(
            accessToken: "token-123", refreshToken: "refresh-123", extras: ["chatgpt_account_id": "acct-456"]
        )))

        let outcome = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.url), [
            CodexUsageClient.resetCreditsURL, CodexLogin.tokenURL, CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL
        ])
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer token-new")
    }

    func testClaimWithNoMatchingCreditIsNoCreditWithoutConsuming() async throws {
        let http = makeHTTP(listBody: Data(#"{"credits": [], "available_count": 0}"#.utf8))
        let runtime = try makeRuntime(http: http)

        let outcome = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL], "no consume POST is ever sent")
    }

    func testClaimFailuresCollapseToFriendlyOutcomes() async throws {
        let noRequests = RoutingHTTPClient { request in
            XCTFail("no request should be sent without a credential: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let cases: [(name: String, runtime: AccountProviderRuntime, expected: ResetClaimOutcome)] = [
            ("list down", try makeRuntime(http: makeHTTP(listStatus: 503)), .failed(.refused)),
            ("list rejected", try makeRuntime(http: makeHTTP(listStatus: 401)), .failed(.signInExpired)),
            ("consume down", try makeRuntime(http: makeHTTP(consumeStatus: 500, consumeBody: Data("gateway error".utf8))),
             .failed(.refused)),
            ("signed out", try makeRuntime(http: noRequests, credential: nil), .failed(.signInExpired))
        ]

        for entry in cases {
            let outcome = await entry.runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")
            XCTAssertEqual(outcome, entry.expected, entry.name)
        }
    }

    func testClaimNothingToResetKeepsTheCredit() async throws {
        let runtime = try makeRuntime(http: makeHTTP(consumeBody: Self.consumeBody(code: "nothing_to_reset")))

        let outcome = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .nothingToReset)
    }

    func testLostConsumeAnswerIsRetriedWithTheSameKeyAndCredit() async throws {
        let consumed = TestSwitch(false)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                let body = consumed.value ? Data(#"{"credits": [], "available_count": 0}"#.utf8) : Self.listBody()
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            case CodexUsageClient.consumeResetCreditURL:
                guard consumed.value else {
                    consumed.value = true
                    throw URLError(.networkConnectionLost)
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "already_redeemed"))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let runtime = try makeRuntime(http: http)

        let first = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")
        let retry = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(first, .failed(.connection))
        XCTAssertEqual(retry, .success, "already_redeemed proves the original claim landed")
        XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.resetCreditsURL }.count, 1, "the replay skips matching")
        let replay = try XCTUnwrap(http.requests.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(replay.body)) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the originally matched credit id")
        XCTAssertEqual(payload["redeem_request_id"], "redeem-1")
    }

    func testRefreshReadsEachCreditsExpiryWithTheAccountsLogin() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit_reset_credits":{"available_count":2}}"#.utf8))
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = try makeRuntime(http: http)

        let snapshot = try await runtime.refresh().get()

        guard case .values(_, let values, let expiries) = snapshot.line(label: "Rate Limit Resets") else {
            return XCTFail("expected the Rate Limit Resets row")
        }
        XCTAssertEqual(values, [MetricValue(number: 2, kind: .count, label: "available")])
        XCTAssertEqual(expiries, [Self.expiry, Self.expiry.addingTimeInterval(999_999)])
        let creditsRequest = try XCTUnwrap(http.requests.first { $0.url == CodexUsageClient.resetCreditsURL })
        XCTAssertEqual(creditsRequest.headers["Authorization"], "Bearer token-123")
        XCTAssertEqual(creditsRequest.headers["ChatGPT-Account-Id"], "acct-456")
    }

    func testAClaimThatFindsNoCreditMakesItsRefreshReadTheListAgain() async throws {
        let spent = TestSwitch(false)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                let count = spent.value ? 0 : 1
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit_reset_credits":{"available_count":\#(count)}}"#.utf8))
            case CodexUsageClient.resetCreditsURL:
                let body = spent.value ? Data(#"{"credits": [], "available_count": 0}"#.utf8) : Self.listBody()
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = try makeRuntime(http: http)
        _ = try await runtime.refresh().get()
        spent.value = true

        let outcome = await runtime.claimCodexResetCredit(expiringAt: Self.expiry, redeemRequestID: "redeem-1")
        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(http.requests.count { $0.url == CodexUsageClient.resetCreditsURL }, 3, "the pass, the claim, and the claim's refresh")
        guard case .values(_, let values, let expiries) = snapshot.line(label: "Rate Limit Resets") else {
            return XCTFail("expected the Rate Limit Resets row")
        }
        XCTAssertEqual(values, [MetricValue(number: 0, kind: .count, label: "available")])
        XCTAssertTrue(expiries.isEmpty)
    }

    func testRefreshFallsBackToTheUsageCountWhenTheCreditListFails() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit_reset_credits":{"available_count":1}}"#.utf8))
            case CodexUsageClient.resetCreditsURL:
                throw URLError(.timedOut)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = try makeRuntime(http: http)

        let snapshot = try await runtime.refresh().get()

        guard case .values(_, let values, let expiries) = snapshot.line(label: "Rate Limit Resets") else {
            return XCTFail("expected the Rate Limit Resets row")
        }
        XCTAssertEqual(values, [MetricValue(number: 1, kind: .count, label: "available")])
        XCTAssertTrue(expiries.isEmpty)
    }

    private func makeHTTP(
        listStatus: Int = 200,
        listBody: Data = listBody(),
        consumeStatus: Int = 200,
        consumeBody: Data = consumeBody(code: "reset")
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: listStatus, headers: [:], body: listBody)
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: consumeStatus, headers: [:], body: consumeBody)
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
    }

    private func makeRuntime(
        http: RoutingHTTPClient,
        credential: AccountCredential? = .oauth(OAuthTokens(accessToken: "token-123", extras: ["chatgpt_account_id": "acct-456"]))
    ) throws -> AccountProviderRuntime {
        let account = Account(kind: .codex, label: "Work")
        let vault = InMemoryCredentialVault()
        if let credential { try vault.save(credential, for: account.id) }
        return AccountProviderRuntime(account: account, vault: vault, http: http)
    }
}
