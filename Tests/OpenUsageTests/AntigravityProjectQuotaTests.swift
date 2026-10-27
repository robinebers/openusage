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

    private func refresh(summaryStatus: Int? = nil) async throws -> ProviderSnapshot {
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
        let snapshot = try await refresh()

        XCTAssertNil(snapshot.errorMessage, "\(snapshot.lines)")
        XCTAssertEqual(snapshot.lines.map(\.label), [AntigravityMetric.weeklyLabel, AntigravityMetric.claudeWeeklyLabel])
        XCTAssertEqual(snapshot.plan, "Antigravity Starter Quota")
    }

    func testRejectedQuotaCallReadsAsExpiredSignIn() async throws {
        let snapshot = try await refresh(summaryStatus: 403)

        guard let text = snapshot.errorMessage else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(.antigravity).localizedDescription)
    }

    /// Robin: the plans read "Google AI Pro" and "Google AI Ultra", the names Google sells them as,
    /// whether `loadCodeAssist` names the paid tier by id or buries the tier word in a longer name; a
    /// tier Google names otherwise keeps its name.
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
