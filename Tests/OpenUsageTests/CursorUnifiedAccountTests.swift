import XCTest
@testable import OpenUsage

/// A unified Cursor account (Cursor, X and Grok merged) has one weekly included pool, pays additional usage
/// from prepaid credits, and keeps those credits in `GetComplatCreditBalance`. Shapes from SCO-181.
@MainActor
final class CursorUnifiedAccountTests: XCTestCase {
    nonisolated private static let accessToken = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "") + ".sig"

    nonisolated private static let weeklyUsage = #"""
    {"autoBucketModels":["fake-model"],"billingCycleEnd":"1795333076119","billingCycleStart":"1794728276119",
     "displayMessage":"fake","displayThreshold":200,"enabled":true,
     "planUsage":{"autoPercentUsed":0.1083130246412131,"bonusTooltip":"fake","totalPercentUsed":0.1083130246412131},
     "spendLimitUsage":{"limitType":"user"}}
    """#

    nonisolated private static let mergedPlan = #"""
    {"isMerged":true,"planInfo":{"billingCycleEnd":"1797320277830","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY",
     "includedUsageResetsAt":"1795333076119","planName":"Ultra","price":""}}
    """#

    nonisolated private static let sand = #"""
    {"additionalUsageLimit":{"resetsAt":"2026-12-01T00:00:00Z","spentCents":"0","state":"STATE_NONE"},
     "billingBrand":"SAND_BILLING_BRAND_GROK","currentPeriodStart":"2026-11-15T07:37:56.119Z","cursorPlanName":"Ultra",
     "grokPlanLabel":"fake","hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"isUnified":true,
     "nextResetTimestampUtc":"2026-11-22T07:37:56.119Z","prepaidAvailableCents":"0","usagePercent":0.1083130246412131}
    """#

    nonisolated private static let stripe = #"""
    {"customerBalance":0,"isOnBillableAuto":true,"membershipType":"unified_ultra","planAccess":{"isMerged":true,"status":"ready"},
     "subscriptionStatus":"active"}
    """#

    nonisolated private static let summary = #"""
    {"billingCycleEnd":"2026-12-01T00:00:00.000Z","billingCycleStart":"2026-11-01T00:00:00.000Z","isUnlimited":false,
     "individualUsage":{"onDemand":{"enabled":false,"limit":null,"remaining":null,"used":0},
                        "plan":{"enabled":true,"limit":55395,"remaining":55395,"used":0}},
     "limitType":"user","membershipType":"unified_ultra","teamUsage":{}}
    """#

    nonisolated private static let complatBalance = #"""
    {"cursorCreditInFlightCents":"0","cursorCreditPendingCents":"0","cursorCreditRefundRequestedCents":"0",
     "usdRemainingCents":"581149"}
    """#

    nonisolated private static func usageStatus(_ monthly: String) -> String {
        #"""
        {"availability":"available","monthlyUsage":{\#(monthly),"creditsUsedCents":0,
         "periodStart":"2026-11-01T00:00:00.000Z","resetsAt":"2026-12-01T00:00:00.000Z"},
         "weeklyIncludedStatus":{"status":"metered"},
         "weeklyIncludedUsage":{"budgetCents":55395,"periodStart":"2026-11-15T07:37:56.119Z","resetCounter":3,
                                "resetsAt":"2026-11-22T07:37:56.119Z","usedCents":69},
         "weeklyIncludedUsageByProduct":[{"cents":35,"product":"fake"},{"cents":34,"product":"fake-2"}]}
        """#
    }

    nonisolated private static let uncappedStatus = usageStatus(#""additionalUsageOff":false,"limitCents":null,"usedCents":0"#)

    private func refresh(
        plan: String = mergedPlan,
        usageStatus: String? = uncappedStatus,
        complat: String? = complatBalance
    ) async throws -> (data: [String: WidgetData], paths: [String]) {
        let account = Account(kind: .cursor, label: "Cursor")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: Self.accessToken, refreshToken: "refresh")), for: account.id)
        let http = RoutingHTTPClient { request in
            let body: String? = switch request.url.path {
            case CursorUsageClient.usageURL.path: Self.weeklyUsage
            case CursorUsageClient.planURL.path: plan
            case CursorUsageClient.creditsURL.path: "{}"
            case CursorUsageClient.stripeURL.path: Self.stripe
            case CursorUsageClient.grokBotUsageURL.path: Self.sand
            case CursorUsageClient.usageSummaryURL.path: Self.summary
            case CursorUsageClient.complatCreditBalanceURL.path: complat
            case CursorUsageClient.usageStatusURL.path: usageStatus
            case CursorUsageClient.usageEventsURL.path: #"{"totalUsageEventsCount":0}"#
            default: nil
            }
            guard let body else { return HTTPResponse(statusCode: 404, headers: [:], body: Data()) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        var data: [String: WidgetData] = [:]
        for descriptor in runtime.widgetDescriptors {
            let widget = store.data(for: descriptor)
            if widget.hasData { data[widget.title] = widget }
        }
        return (data, http.requests.map(\.url.path))
    }

    func testAUnifiedAccountShowsOneWeeklyPoolAdditionalUsageAndItsCreditBalance() async throws {
        let (data, paths) = try await refresh()

        XCTAssertEqual(Set(data.keys), ["Total Usage", "Extra Usage", "Credits", "Today", "Yesterday", "Last 30 Days"])
        XCTAssertEqual(try XCTUnwrap(data["Total Usage"]?.used), 0.1083, accuracy: 0.0001)
        XCTAssertEqual(data["Total Usage"]?.resetsAt, Date(timeIntervalSince1970: 1_795_333_076.119))
        XCTAssertEqual(data["Credits"]?.values.first?.number, 5811.49, "the dashboard's Credits card")
        XCTAssertEqual(data["Extra Usage"]?.values.first?.number, 0, "no cap: what was spent this month, shown at $0")
        XCTAssertEqual(data["Extra Usage"]?.values.first?.kind, .dollars)
        XCTAssertNil(data["Extra Usage"]?.limit)
        XCTAssertTrue(paths.contains(CursorUsageClient.complatCreditBalanceURL.path))
        for unread in [CursorUsageClient.creditsURL, CursorUsageClient.stripeURL, CursorUsageClient.grokBotUsageURL] {
            XCTAssertFalse(paths.contains(unread.path), "\(unread.path) is read only for accounts that are not unified")
        }
    }

    func testAUnifiedAccountWithAMonthlyLimitShowsAdditionalUsageAgainstIt() async throws {
        let (data, _) = try await refresh(
            usageStatus: Self.usageStatus(#""additionalUsageOff":false,"limitCents":10000,"usedCents":2500"#)
        )

        XCTAssertEqual(data["Extra Usage"]?.kind, .dollars)
        XCTAssertEqual(data["Extra Usage"]?.used, 25)
        XCTAssertEqual(data["Extra Usage"]?.limit, 100)
        XCTAssertEqual(data["Extra Usage"]?.resetsAt, OpenUsageISO8601.date(from: "2026-12-01T00:00:00.000Z"))
    }

    func testAUnifiedAccountHidesAdditionalUsageWhenItIsOff() async throws {
        for monthly in [
            #""additionalUsageOff":true,"limitCents":null,"usedCents":0"#,
            #""limitCents":0,"usedCents":0"#
        ] {
            let (data, _) = try await refresh(usageStatus: Self.usageStatus(monthly))

            XCTAssertNil(data["Extra Usage"], monthly)
            XCTAssertNotNil(data["Credits"], monthly)
        }
    }

    func testAUnifiedAccountShowsZeroCreditsWhenCursorOmitsTheBalance() async throws {
        let (data, _) = try await refresh(complat: "{}")

        XCTAssertEqual(data["Credits"]?.values.first?.number, 0, "Connect JSON leaves out a zero balance")
    }

    func testAnAccountThatIsNotUnifiedNeverReadsTheUnifiedEndpoints() async throws {
        for plan in [#"{"planInfo":{"planName":"Ultra"}}"#, #"{"isMerged":false,"planInfo":{"planName":"Ultra"}}"#] {
            let (data, paths) = try await refresh(plan: plan)

            XCTAssertNotNil(data["Cursor Models"], plan)
            XCTAssertNotNil(data["Grok Bot"], plan)
            XCTAssertEqual(data["Credits"]?.values.first?.number, 0, "grants {} and Stripe 0, as before")
            XCTAssertFalse(paths.contains(CursorUsageClient.complatCreditBalanceURL.path), plan)
            XCTAssertFalse(paths.contains(CursorUsageClient.usageStatusURL.path), plan)
            XCTAssertTrue(paths.contains(CursorUsageClient.creditsURL.path), plan)
            XCTAssertTrue(paths.contains(CursorUsageClient.stripeURL.path), plan)
        }
    }
}
