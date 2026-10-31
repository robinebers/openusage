import os
import XCTest
@testable import OpenUsage

/// Free-tier Google accounts get 403 SUBSCRIPTION_REQUIRED from `retrieveUserQuotaSummary` unless the
/// request names the account's Cloud Code project from `loadCodeAssist`. Shapes taken from the live
/// API on 2026-10-23; values are fake.
@MainActor
final class AntigravityProjectQuotaTests: XCTestCase {
    nonisolated private static let loadCodeAssist = #"""
    {"allowedTiers":[{"id":"free-tier","isDefault":true,"name":"Antigravity Starter Quota"},{"id":"standard-tier","name":"Standard"}],
     "cloudaicompanionProject":"fake-project-123","currentTier":{"id":"free-tier","name":"Antigravity Starter Quota"},
     "gcpManaged":false,"paidTier":{"id":"free-tier","name":"Antigravity Starter Quota"}}
    """#

    nonisolated private static let quotaSummary = #"""
    {"description":"fake","groups":[
      {"displayName":"Gemini","description":"fake","buckets":[{"bucketId":"gemini-weekly","displayName":"fake","remainingFraction":0.75,"resetTime":"2026-10-27T00:00:00Z","window":"weekly"}]},
      {"displayName":"Claude","description":"fake","buckets":[{"bucketId":"3p-weekly","displayName":"fake","remainingFraction":0.5,"resetTime":"2026-10-27T00:00:00Z","window":"weekly"}]}]}
    """#

    nonisolated private static let subscriptionRequired = #"""
    {"error":{"code":403,"message":"fake","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SUBSCRIPTION_REQUIRED","domain":"cloudaicompanion.googleapis.com"}]}}
    """#

    private func refresh(summaryStatus: Int? = nil) async throws -> Result<ProviderSnapshot, RefreshFailure> {
        let account = Account(kind: .antigravity, label: "Google Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case AntigravityUsageClient.loadCodeAssistPath:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.loadCodeAssist.utf8))
            case AntigravityUsageClient.quotaSummaryPath:
                let project = request.body.flatMap(ProviderParse.jsonObject)?["project"] as? String
                if let summaryStatus {
                    return HTTPResponse(statusCode: summaryStatus, headers: [:], body: Data(Self.subscriptionRequired.utf8))
                }
                guard project == "fake-project-123" else {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data(Self.subscriptionRequired.utf8))
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.quotaSummary.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        return await AccountProviderRuntime(account: account, vault: vault, http: http).refresh()
    }

    func testQuotaSummaryNamesTheAccountsProject() async throws {
        let snapshot = try await refresh().get()

        XCTAssertEqual(snapshot.lines.map(\.label), [AntigravityMetric.weeklyLabel, AntigravityMetric.claudeWeeklyLabel])
        XCTAssertEqual(snapshot.plan, "Antigravity Starter Quota")
    }

    func testRejectedQuotaCallReadsAsExpiredSignIn() async throws {
        let snapshot = try await refresh(summaryStatus: 403)

        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(.antigravity).localizedDescription)
    }

    func testEveryBaseOfflineIsUnreachable() async throws {
        let account = Account(kind: .antigravity, label: "Google Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)), for: account.id)
        let http = RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) }

        let failure = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().failure

        XCTAssertEqual(http.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.count, 2)
        XCTAssertEqual(failure?.kind, .unreachable)
    }

    func testAnUnauthorizedQuotaReadRenewsTheSignInOnceAndRetries() async throws {
        let account = Account(kind: .antigravity, label: "Google Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantFuture)), for: account.id)
        let http = RoutingHTTPClient { request in
            if request.url == AntigravityLogin.tokenURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            }
            switch request.url.path {
            case AntigravityUsageClient.loadCodeAssistPath:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.loadCodeAssist.utf8))
            case AntigravityUsageClient.quotaSummaryPath where request.headers["Authorization"] == "Bearer new-access":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.quotaSummary.utf8))
            default:
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
        }

        let snapshot = try await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().get()

        XCTAssertEqual(snapshot.lines.map(\.label), [AntigravityMetric.weeklyLabel, AntigravityMetric.claudeWeeklyLabel])
        XCTAssertEqual(http.requests.filter { $0.url == AntigravityLogin.tokenURL }.count, 1)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("Expected saved tokens") }
        XCTAssertEqual(saved.accessToken, "new-access")
    }

    func testAFailedProjectLookupIsReadAgainOnTheNextRefresh() async throws {
        let account = Account(kind: .antigravity, label: "Google Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)), for: account.id)
        let lookupWorks = OSAllocatedUnfairLock(initialState: false)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case AntigravityUsageClient.loadCodeAssistPath:
                guard lookupWorks.withLock({ $0 }) else { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.loadCodeAssist.utf8))
            case AntigravityUsageClient.quotaSummaryPath:
                guard request.body.flatMap(ProviderParse.jsonObject)?["project"] as? String == "fake-project-123" else {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data(Self.subscriptionRequired.utf8))
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.quotaSummary.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let first = await runtime.refresh()
        XCTAssertNotNil(first.failure)

        lookupWorks.withLock { $0 = true }
        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.lines.map(\.label), [AntigravityMetric.weeklyLabel, AntigravityMetric.claudeWeeklyLabel])
        XCTAssertEqual(snapshot.plan, "Antigravity Starter Quota")
    }

    func testPaidTiersReadAsGoogleSellsThem() {
        func plan(id: String, name: String) -> String? {
            AntigravityUsageMapper.parseLoadCodeAssistPlan(Data(#"{"paidTier":{"id":"\#(id)","name":"\#(name)"}}"#.utf8))
        }
        XCTAssertEqual(plan(id: "g1-pro-tier", name: "fake"), "Google AI Pro")
        XCTAssertEqual(plan(id: "g1-ultra-tier", name: "fake"), "Google AI Ultra")
        XCTAssertEqual(plan(id: "g1-ultra-lite-tier", name: "fake"), "Google AI Ultra Lite")
        XCTAssertEqual(plan(id: "unknown-tier", name: "Google AI Pro"), "Google AI Pro")
        XCTAssertEqual(plan(id: "unknown-tier", name: "Gemini Code Assist in Google One AI Pro"), "Google AI Pro")
        XCTAssertEqual(plan(id: "unknown-tier", name: "Google AI Ultra Lite"), "Google AI Ultra Lite")
        XCTAssertEqual(plan(id: "free-tier", name: "Antigravity Starter Quota"), "Antigravity Starter Quota")
        XCTAssertNil(plan(id: "unknown-tier", name: ""))
    }
}
