import XCTest
@testable import OpenUsage

/// A balance shows at $0. Extra Usage shows while the provider has it on, even at $0, and hides while it is off.
@MainActor
final class ZeroBalanceAndExtraUsageTests: XCTestCase {
    private func shownRow(_ kind: ProviderKind, _ lines: [MetricLine], key: String) async -> WidgetData? {
        let account = Account(kind: kind, label: kind.displayName)
        let provider = AccountProviderRuntime.provider(for: account)
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        let runtime = StubRuntime(provider: provider, descriptors: descriptors,
                                  snapshot: ProviderSnapshot(provider: provider, plan: nil, lines: lines))
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        await store.refreshAll()
        return store.accounts(in: [ProviderMetrics(provider: provider, metrics: descriptors)])
            .flatMap(\.lines).first { $0.descriptor.key == key }?.data
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(ProviderParse.jsonObject(Data(text.utf8)))
    }

    private func cursorLines(_ extra: String, creditGrants: String? = nil) throws -> [MetricLine] {
        let usage = try json(#"""
        {"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,
         "planUsage":{"apiPercentUsed":0,"autoPercentUsed":0,"limit":40000,"remaining":40000,"totalPercentUsed":0}\#(extra)}
        """#)
        return try CursorUsageMapper.mapUsage(usage: usage, planName: "Pro", creditGrants: creditGrants.map(json),
                                              stripeBalanceCents: 0).lines
    }

    func testClaudeExtraUsageHidesWhenOffAndShowsZeroSpentWhenOn() async throws {
        func lines(_ extra: String) throws -> [MetricLine] {
            try ClaudeUsageMapper.mapUsageResponse(.json(#"{"five_hour":{"utilization":10},"extra_usage":\#(extra)}"#))
        }
        let off = await shownRow(.claude, try lines(#"{"is_enabled":false,"monthly_limit":null,"used_credits":null}"#), key: "extra")
        XCTAssertNil(off)

        let on = await shownRow(.claude, try lines(#"{"is_enabled":true,"monthly_limit":null,"used_credits":0}"#), key: "extra")
        XCTAssertEqual(on?.unboundedDetail, "$0 spent")

        let capped = await shownRow(.claude, try lines(#"{"is_enabled":true,"monthly_limit":5000,"used_credits":0}"#), key: "extra")
        XCTAssertEqual(capped?.limit, 50)
        XCTAssertEqual(capped?.used, 0)
    }

    func testCursorExtraUsageHidesWithNoLimitAndShowsAZeroBarWithOne() async throws {
        let off = await shownRow(.cursor, try cursorLines(#","spendLimitUsage":{"limitType":"user"}"#), key: "onDemand")
        XCTAssertNil(off)

        let on = await shownRow(.cursor, try cursorLines(
            #","spendLimitUsage":{"individualLimit":5000,"individualRemaining":5000,"limitType":"user"}"#), key: "onDemand")
        XCTAssertEqual(on?.limit, 50)
        XCTAssertEqual(on?.used, 0)
    }

    func testCopilotExtraUsageHidesWhenNotPermittedAndShowsZeroWhenPermitted() async throws {
        func lines(permitted: Bool) throws -> [MetricLine] {
            try CopilotUsageMapper.map(body: json(#"""
            {"copilot_plan":"individual","quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":
             {"entitlement":300,"remaining":300,"percent_remaining":100,"overage_permitted":\#(permitted),"overage_count":0}}}
            """#)).lines
        }
        let off = await shownRow(.copilot, try lines(permitted: false), key: "extra")
        XCTAssertNil(off)

        let on = await shownRow(.copilot, try lines(permitted: true), key: "extra")
        XCTAssertEqual(on?.unboundedDetail, "0")
    }

    func testGrokExtraUsageHidesWithNoPayAsYouGoCapAndShowsTheCap() async throws {
        func lines(_ cap: String) throws -> [MetricLine] {
            try GrokUsageMapper.mapCreditsConfig(.json(#"""
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-30T21:36:52Z",
             "end":"2026-07-07T21:36:52Z"}\#(cap)}}
            """#)).lines
        }
        let off = await shownRow(.grok, try lines(""), key: "payAsYouGo")
        XCTAssertNil(off)

        let on = await shownRow(.grok, try lines(#","onDemandCap":{"val":2500}"#), key: "payAsYouGo")
        XCTAssertEqual(on?.unboundedDetail, "2500 cap")
    }

    func testDevinExtraUsageShowsAReportedZeroBalanceAndHidesWhenWindsurfReportsNone() async throws {
        func lines(_ balance: String) throws -> [MetricLine] {
            try DevinUsageMapper.map(Data(#"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":40\#(balance)}}}"#.utf8)).lines
        }
        let reported = await shownRow(.devin, try lines(#","overageBalanceMicros":"0""#), key: "extra")
        XCTAssertEqual(reported?.unboundedDetail, "$0 left")

        let none = await shownRow(.devin, try lines(""), key: "extra")
        XCTAssertNil(none)
    }

    func testBalancesShowAtZero() async throws {
        let openRouter = try OpenRouterUsageMapper.creditsLines(Data(#"{"data":{"total_credits":10,"total_usage":10}}"#.utf8))
        let balance = await shownRow(.openrouter, openRouter, key: "balance")
        XCTAssertEqual(balance?.unboundedDetail, "$0 left")

        let ollama = try OllamaUsageMapper.balanceLines(Data(
            #"{"included":{"balance_usd":100,"allowance_usd":100},"purchased":{"balance_usd":0}}"#.utf8))
        let purchased = await shownRow(.ollama, ollama, key: "purchasedCredits")
        XCTAssertEqual(purchased?.unboundedDetail, "$0 left")

        let cursor = await shownRow(.cursor, try cursorLines("", creditGrants: #"{"hasCreditGrants":false}"#), key: "credits")
        XCTAssertEqual(cursor?.unboundedDetail, "$0 left")

        let unread = await shownRow(.cursor, try cursorLines(""), key: "credits")
        XCTAssertNil(unread, "a failed credit-grants read is not a $0 balance")
    }
}
