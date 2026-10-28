import XCTest
@testable import OpenUsage

@MainActor
final class CursorCurrentPeriodUsageTests: XCTestCase {
    nonisolated private static let currentPeriodUsage = #"""
    {"autoBucketModels":["fake-model"],"autoModelSelectedDisplayMessage":"fake","billingCycleEnd":"1764547200000",
     "billingCycleStart":"1761955200000","displayMessage":"fake","displayThreshold":50,"enabled":true,
     "namedModelSelectedDisplayMessage":"fake",
     "planUsage":{"apiPercentUsed":12.5,"autoPercentUsed":3.25,"bonusTooltip":"fake","limit":2000,"remaining":1500,
                  "remainingBonus":false,"totalPercentUsed":25},
     "spendLimitUsage":{"individualLimit":5000,"individualRemaining":4000,"limitType":"user"}}
    """#

    nonisolated private static let sandUsage = #"""
    {"billingBrand":"fake","currentPeriodStart":"2026-10-20T00:00:00Z","cursorPlanName":"fake","grokPlanLabel":"fake",
     "hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"usagePercent":10}
    """#

    private func runtime(usage: HTTPResponse) throws -> AccountProviderRuntime {
        let account = Account(kind: .cursor, label: "Cursor Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access", refreshToken: "refresh")), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL: return usage
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            case CursorUsageClient.grokBotUsageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.sandUsage.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        return AccountProviderRuntime(account: account, vault: vault, http: http)
    }

    func testTopLevelUsageFillsEveryCursorTile() async throws {
        let runtime = try runtime(usage: HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.currentPeriodUsage.utf8)))

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Pro")
        guard case .progress(_, let used, let limit, _, let resetsAt, _)? = snapshot.line(label: "Total usage") else {
            return XCTFail("Missing Total usage in \(snapshot.lines)")
        }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_764_547_200))
        for label in ["Total usage", "Cursor Models", "Other Models", "On-demand", "Grok Bot usage"] {
            XCTAssertNotNil(snapshot.line(label: label), "\(label) has no line")
        }
    }

    func testRejectedTokenReadsAsExpiredSignIn() async throws {
        let runtime = try runtime(usage: HTTPResponse(statusCode: 401, headers: [:], body: Data()))

        let snapshot = await runtime.refresh()

        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(.cursor).localizedDescription)
    }
}
