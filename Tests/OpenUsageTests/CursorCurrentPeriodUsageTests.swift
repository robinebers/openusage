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
            case CursorUsageClient.refreshURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"renewed"}"#.utf8))
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

    /// #1424: a team's pooled spend limit must not read like a personal Extra Usage cap.
    func testATeamPoolReadsAsTeamSpendAndAPersonalCapStaysExtraUsage() async throws {
        let team = Self.currentPeriodUsage.replacingOccurrences(
            of: #""individualLimit":5000,"individualRemaining":4000,"limitType":"user""#,
            with: #""pooledLimit":50000,"pooledUsed":12000,"pooledRemaining":38000,"limitType":"team""#
        )
        let teamRow = try await onDemandRow(team)
        XCTAssertEqual(teamRow?.title, "Team Spend")
        XCTAssertEqual(teamRow?.used, 120)
        XCTAssertEqual(teamRow?.limit, 500)

        let personalRow = try await onDemandRow(Self.currentPeriodUsage)
        XCTAssertEqual(personalRow?.title, "Extra Usage")
        XCTAssertEqual(personalRow?.limit, 50)
    }

    private func onDemandRow(_ usage: String) async throws -> WidgetData? {
        let runtime = try runtime(usage: HTTPResponse(statusCode: 200, headers: [:], body: Data(usage.utf8)))
        let snapshot = try await runtime.refresh().get()
        let stub = StubRuntime(provider: runtime.provider, descriptors: runtime.widgetDescriptors, snapshot: snapshot)
        let store = WidgetDataStore.forTesting([stub], defaults: isolatedDefaults())
        await store.refreshAll()
        return store.accounts(in: [ProviderMetrics(provider: stub.provider, metrics: stub.widgetDescriptors)])
            .flatMap(\.lines).first { $0.descriptor.key == "onDemand" }?.data
    }

    func testRejectedTokenReadsAsExpiredSignIn() async throws {
        let runtime = try runtime(usage: HTTPResponse(statusCode: 401, headers: [:], body: Data()))

        let snapshot = await runtime.refresh()

        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(.cursor).localizedDescription)
        let usageTokens = (runtime.http as? RoutingHTTPClient)?.requests
            .filter { $0.url == CursorUsageClient.usageURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(usageTokens, ["Bearer access", "Bearer renewed"], "the renewed token is rejected too")
    }
}
