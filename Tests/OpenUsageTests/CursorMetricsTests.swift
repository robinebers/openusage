import XCTest
@testable import OpenUsage

/// Every Cursor metric that comes from Cursor's API. Response shapes match the live API on 2026-10-23;
/// every value is fake.
@MainActor
final class CursorMetricsTests: XCTestCase {
    /// A JWT whose subject carries the user id the cursor.com cookie endpoints need.
    nonisolated private static let accessToken = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "") + ".sig"

    nonisolated private static let individualUsage = #"""
    {"autoBucketModels":["fake-model"],"autoModelSelectedDisplayMessage":"fake","billingCycleEnd":"1764547200000",
     "billingCycleStart":"1761955200000","displayMessage":"fake","displayThreshold":50,"enabled":true,
     "namedModelSelectedDisplayMessage":"fake",
     "planUsage":{"apiPercentUsed":40,"autoPercentUsed":20,"bonusTooltip":"fake","limit":40000,"remaining":30000,
                  "remainingBonus":false,"totalPercentUsed":25},
     "spendLimitUsage":{"individualLimit":50000,"individualRemaining":38000,"limitType":"user"}}
    """#

    nonisolated private static let planInfo = #"""
    {"planInfo":{"billingCycleEnd":"1764547200000","includedUsagePeriod":"fake","planName":"Ultra","planOwner":"fake","price":"fake"}}
    """#

    nonisolated private static let stripe = #"""
    {"customerBalance":-2500,"individualMembershipType":"ultra","isOnBillableAuto":false,"isOnStudentPlan":false,
     "isTeamMember":false,"isYearlyPlan":false,"lastPaymentFailed":false,"membershipType":"ultra","paymentId":"fake",
     "studentDiscountApplied":false,"subscriptionStatus":"active","trialEligible":false,"trialLengthDays":0,
     "trialWasCancelled":false,"verifiedStudent":false}
    """#

    nonisolated private static let creditGrants = #"{"hasCreditGrants":true,"totalCents":10000,"usedCents":4000}"#

    nonisolated private static let grokBot = #"""
    {"billingBrand":"fake","currentPeriodStart":"2026-10-20T00:00:00Z","cursorPlanName":"fake","grokPlanLabel":"fake",
     "hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"nextResetTimestampUtc":"2026-10-27T00:00:00Z",
     "unifiedPlanMigration":{"href":"fake"},"upgradeRecommendations":[],"usagePercent":30}
    """#

    /// A request-based Enterprise seat: the primary body carries no limit, pools or total.
    nonisolated private static let enterpriseUsage = #"{"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,"planUsage":{}}"#
    nonisolated private static let requestUsage = #"{"gpt-4":{"numRequests":120,"maxRequestUsage":500},"startOfMonth":"2026-10-01T00:00:00Z"}"#
    nonisolated private static let enterpriseSummary = #"""
    {"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"enterprise",
     "individualUsage":{"onDemand":{"enabled":true,"used":2500,"limit":10000}}}
    """#

    /// A team seat with model pools: the primary body has no on-demand, usage-summary does.
    nonisolated private static let teamUsage = #"""
    {"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,
     "planUsage":{"apiPercentUsed":10,"autoPercentUsed":5,"limit":2000,"totalSpend":300,"totalPercentUsed":7},
     "spendLimitUsage":{"limitType":"team"}}
    """#
    nonisolated private static let teamSummary = #"""
    {"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"team",
     "individualUsage":{"onDemand":{"enabled":true,"used":1500,"limit":20000}}}
    """#

    private func refresh(
        usage: String,
        planName: String,
        summary: String? = nil,
        requests: String? = nil
    ) async throws -> (plan: String?, data: [String: WidgetData], paths: [String]) {
        let account = Account(kind: .cursor, label: "Cursor")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: Self.accessToken, refreshToken: "refresh")), for: account.id)
        let plan = Self.planInfo.replacingOccurrences(of: "Ultra", with: planName)
        let http = RoutingHTTPClient { request in
            let body: String? = switch request.url.path {
            case CursorUsageClient.usageURL.path: usage
            case CursorUsageClient.planURL.path: plan
            case CursorUsageClient.creditsURL.path: Self.creditGrants
            case CursorUsageClient.stripeURL.path: Self.stripe
            case CursorUsageClient.grokBotUsageURL.path: Self.grokBot
            case CursorUsageClient.usageSummaryURL.path: summary
            case CursorUsageClient.restUsageURL.path: requests
            default: nil
            }
            guard let body else { return HTTPResponse(statusCode: 404, headers: [:], body: Data()) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        var data: [String: WidgetData] = [:]
        for descriptor in runtime.widgetDescriptors {
            let widget = store.data(for: descriptor)
            if widget.hasData { data[widget.title] = widget }
        }
        return (store.plan(for: runtime.provider.id), data, http.requests.map(\.url.path))
    }

    func testTheCardHasEveryOriginalMetricTitle() throws {
        let account = Account(kind: .cursor, label: "Cursor")
        let runtime = AccountProviderRuntime(account: account, vault: InMemoryCredentialVault())
        XCTAssertEqual(runtime.widgetDescriptors.map(\.sample.title), [
            "Total Usage", "Cursor Models", "Other Models", "Extra Usage", "Grok Bot", "Requests", "Credits"
        ])
    }

    func testAnIndividualSeatShowsUsagePoolsExtraUsageGrokBotAndCredits() async throws {
        let (plan, data, paths) = try await refresh(usage: Self.individualUsage, planName: "Ultra")

        XCTAssertEqual(plan, "Ultra")
        XCTAssertEqual(Set(data.keys), ["Total Usage", "Cursor Models", "Other Models", "Extra Usage", "Grok Bot", "Credits"])
        XCTAssertEqual(data["Total Usage"]?.used, 25)
        XCTAssertEqual(data["Cursor Models"]?.used, 20)
        XCTAssertEqual(data["Other Models"]?.used, 40)
        XCTAssertEqual(data["Extra Usage"]?.kind, .dollars)
        XCTAssertEqual(data["Extra Usage"]?.used, 120)
        XCTAssertEqual(data["Extra Usage"]?.limit, 500)
        XCTAssertEqual(data["Grok Bot"]?.used, 30)
        XCTAssertEqual(data["Grok Bot"]?.resetsAt, OpenUsageISO8601.date(from: "2026-10-27T00:00:00Z"))
        XCTAssertNil(data["Credits"]?.limit)
        XCTAssertEqual(data["Credits"]?.values.first?.number, 85, "grants $100 - $40 used + $25 prepaid")
        XCTAssertFalse(paths.contains(CursorUsageClient.usageSummaryURL.path), "a personal seat never asks usage-summary")
        XCTAssertFalse(paths.contains(CursorUsageClient.restUsageURL.path))
    }

    func testARequestBasedEnterpriseSeatShowsRequestsAndExtraUsageFromTheRestEndpoints() async throws {
        let (plan, data, _) = try await refresh(
            usage: Self.enterpriseUsage, planName: "Enterprise",
            summary: Self.enterpriseSummary, requests: Self.requestUsage
        )

        XCTAssertEqual(plan, "Enterprise")
        XCTAssertEqual(Set(data.keys), ["Total Usage", "Requests", "Extra Usage", "Grok Bot"])
        XCTAssertEqual(data["Requests"]?.kind, .count)
        XCTAssertEqual(data["Requests"]?.used, 120)
        XCTAssertEqual(data["Requests"]?.limit, 500)
        XCTAssertEqual(data["Total Usage"]?.used, 120)
        XCTAssertEqual(data["Extra Usage"]?.used, 25)
        XCTAssertEqual(data["Extra Usage"]?.limit, 100)
    }

    func testATeamSeatTakesExtraUsageAndMembershipFromUsageSummary() async throws {
        let (plan, data, _) = try await refresh(usage: Self.teamUsage, planName: "Pro", summary: Self.teamSummary)

        XCTAssertEqual(plan, "Team", "GetPlanInfo still says Pro for team seats")
        XCTAssertEqual(data["Total Usage"]?.used, 7)
        XCTAssertEqual(data["Extra Usage"]?.used, 15)
        XCTAssertEqual(data["Extra Usage"]?.limit, 200)
    }

    func testTheTwoAccountShapesTogetherFillEveryCursorMetric() async throws {
        let individual = try await refresh(usage: Self.individualUsage, planName: "Ultra")
        let enterprise = try await refresh(
            usage: Self.enterpriseUsage, planName: "Enterprise",
            summary: Self.enterpriseSummary, requests: Self.requestUsage
        )
        let runtime = AccountProviderRuntime(account: Account(kind: .cursor, label: "Cursor"), vault: InMemoryCredentialVault())
        XCTAssertEqual(
            Set(individual.data.keys).union(enterprise.data.keys),
            Set(runtime.widgetDescriptors.map(\.sample.title))
        )
    }
}
