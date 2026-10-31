import XCTest
@testable import OpenUsage

/// Shaped like ChatGPT's live answers for a Pro sign-in (recorded through a CLIProxyAPI hub, ids removed).
enum CodexUsageFixtures {
    static func usage(planType: String = "pro", individualLimit: String = "null") -> String {
        """
        {"plan_type":"\(planType)","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"limit_window_seconds":604800,"reset_after_seconds":481662,"reset_at":1793915535,"used_percent":29},
         "secondary_window":null},"additional_rate_limits":null,"code_review_rate_limit":null,
         "credits":{"approx_cloud_messages":[0,0],"approx_local_messages":[0,0],"balance":"0","has_credits":false,
          "overage_limit_reached":false,"unlimited":false},
         "spend_control":{"individual_limit":\(individualLimit),"reached":false},"rate_limit_reached_type":null,"promo":null,
         "rate_limit_reset_credits":{"applicable_available_count":0,"available_count":0}}
        """
    }

    /// Every day of the 30 is reported, today too, unless `reportsToday` is false. The quiet days report zeros.
    static func counts(reportsToday: Bool = true) -> String {
        let quiet = (3...28).map { "2026-10-\(String(format: "%02d", $0))" } + (reportsToday ? ["2026-10-31"] : [])
        let quietRows = quiet.map { #"{"date":"\#($0)","clients":[],"totals":{"credits":0,"text_total_tokens":0,"threads":0,"turns":0,"users":0}}"# }
        return activeCounts.replacingOccurrences(of: "\"data\":[", with: "\"data\":[" + quietRows.joined(separator: ",") + ",")
    }

    private static let activeCounts = #"""
    {"balance_unit":"credit","group_by":"day","data":[
     {"date":"2026-10-02","clients":[],"totals":{"cached_text_input_tokens":470000000,"credits":16259.4,"text_output_tokens":363029,
      "text_total_tokens":495363029,"threads":40,"turns":392,"uncached_text_input_tokens":25000000,"users":1}},
     {"date":"2026-10-29",
      "clients":[{"cached_text_input_tokens":471808,"client_id":"CODEX_CLI","credits":6.335318,"text_output_tokens":2238,
        "text_total_tokens":567638,"threads":0,"turns":0,"uncached_text_input_tokens":93592,"users":0},
       {"client_id":"CODEX_DESKTOP_APP","credits":0.0,"threads":51,"turns":71,"users":1}],
      "models":[{"credits":0.0,"model":"gpt-6.1-sol","threads":40,"turns":55,"users":1},
       {"credits":0.0,"model":"gpt-6-astra","threads":3,"turns":31,"users":1}],
      "totals":{"cached_text_input_tokens":1475954688,"credits":68877.04709850001,"text_output_tokens":2180573,
       "text_total_tokens":1511437552,"threads":60,"turns":86,"uncached_text_input_tokens":33302291,"users":1}},
     {"date":"2026-10-30","clients":[],"totals":{"cached_text_input_tokens":7183232,"credits":105.64575,"text_output_tokens":27164,
      "text_total_tokens":8139475,"threads":0,"turns":0,"uncached_text_input_tokens":929079,"users":0}}]}
    """#

    /// One event falls before the 30 days.
    static let creditEvents = #"""
    {"data":[
     {"credit_amount":486.03315,"date":"2026-10-29","product_surface":"desktop_app","usage_id":"usage-1"},
     {"credit_amount":2005.8942,"date":"2026-10-17","product_surface":"desktop_app","usage_id":"usage-2"},
     {"credit_amount":307.5,"date":"2026-10-17","product_surface":"exec","usage_id":"usage-3"},
     {"credit_amount":11769.2571,"date":"2026-09-28","product_surface":"desktop_app","usage_id":"usage-4"}]}
    """#

    /// Shaped like the Codex client's team fixture: plan usage in `credits`, charged credits in
    /// `credit_usage_credits` and `on_demand_credits`, and no `units`.
    static let workspaceBreakdown = #"""
    {"data":[
     {"date":"2026-10-30","product_surface_usage_values":{"desktop_app":20.0},
      "premium_usage_values":{"credit_usage_credits":{"cli":4.0,"desktop_app":8.5},"total_usage_credits":{},
       "uncached_text_input_tokens_by_surface":{},"cached_text_input_tokens_by_surface":{},"text_output_tokens_by_surface":{},
       "text_total_tokens_by_surface":{}},
      "models":[{"credits":12.5,"model":"gpt-6-astra","speed":"fast","on_demand_credits":8.0},
       {"credits":2.5,"model":"gpt-6-astra","speed":"standard","on_demand_credits":2.0},
       {"credits":5.0,"model":"gpt-6.1-sol","speed":"standard","on_demand_credits":2.5}]}]}
    """#

    /// A report in relative units, as a personal plan's token report is.
    static let relativeBreakdown = #"""
    {"units":"percent","group_by":"day","data":[{"date":"2026-10-30","product_surface_usage_values":{"desktop_app":100.0},
     "models":[{"credits":100.0,"model":"gpt-6-astra","speed":"fast"}]}]}
    """#

    static let enterpriseCredits = #"""
    {"breakdown":"model","unit":"credits","series":[{"key":"gpt-6-astra","label":"GPT-6 Astra","total":10.0},
     {"key":"gpt-6.1-sol","label":"GPT-6.1 Sol","total":2.5}],
     "data":[{"date":"2026-10-30","values":{"gpt-6-astra":10.0,"gpt-6.1-sol":2.5}}]}
    """#
}

@MainActor
final class CodexUsageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_433_600 + 8 * 3600)

    private func makeAccount(
        planType: String = "pro", individualLimit: String = "null", workspaceBreakdown: String = CodexUsageFixtures.workspaceBreakdown,
        reports: TestSwitch<Int?> = TestSwitch(nil), reportsToday: TestSwitch<Bool> = TestSwitch(true), clock: TestClock? = nil
    ) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient, TestClock) {
        let account = Account(kind: .codex, label: "ChatGPT")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access", refreshToken: "refresh", extras: ["chatgpt_account_id": "acct-fake"])),
                       for: account.id)
        let clock = clock ?? TestClock(now)
        let usage = CodexUsageFixtures.usage(planType: planType, individualLimit: individualLimit)
        let http = RoutingHTTPClient { request in
            let body: String
            switch request.url.path {
            case CodexUsageClient.usageURL.path: body = usage
            case "/backend-api/wham/analytics/daily-workspace-usage-counts": body = CodexUsageFixtures.counts(reportsToday: reportsToday.value)
            case "/backend-api/wham/usage/credit-usage-events": body = CodexUsageFixtures.creditEvents
            case "/backend-api/wham/usage/daily-workspace-user-token-usage-breakdown": body = workspaceBreakdown
            case "/backend-api/wham/usage/daily-workspace-user-credit-usage": body = CodexUsageFixtures.enterpriseCredits
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if request.url.path != CodexUsageClient.usageURL.path, let status = reports.value {
                return HTTPResponse(statusCode: status, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        return (WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now }), runtime, http, clock)
    }

    private func rows(_ store: WidgetDataStore, _ runtime: AccountProviderRuntime) -> [String: String] {
        var rows: [String: String] = [:]
        for descriptor in runtime.widgetDescriptors where descriptor.historyRow != nil {
            let data = store.data(for: descriptor)
            if data.hasData { rows[descriptor.key] = data.unboundedDetail }
        }
        return rows
    }

    private func reportRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url.path.hasPrefix("/backend-api/wham/usage/") || $0.url.path.hasPrefix("/backend-api/wham/analytics/") }
    }

    private func query(_ request: HTTPRequest) -> [String] {
        (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
    }

    private func descriptor(_ runtime: AccountProviderRuntime, _ key: String) throws -> WidgetDescriptor {
        try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == key })
    }

    func testAPersonalPlanShowsTheCreditsChargedTheTokensAndTheTurnsOfEachUTCRange() async throws {
        let (store, runtime, http, _) = try makeAccount()

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), [
            "today": "0 credits · 0 tokens",
            "yesterday": "0 credits · 8.1M tokens",
            "last30": "2.8K credits · 2B tokens",
            "turns": "478 in 30 days"
        ])
        let requests = reportRequests(http)
        XCTAssertEqual(requests.map(\.url.path).sorted(), [
            "/backend-api/wham/analytics/daily-workspace-usage-counts", "/backend-api/wham/usage/credit-usage-events"
        ], "a personal plan reads the credit events, never the relative-unit token report")
        let counts = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("daily-workspace-usage-counts") })
        XCTAssertEqual(query(counts), ["start_date=2026-10-02", "end_date=2026-10-31", "group_by=day", "workspace_user=true"])
        XCTAssertEqual(counts.headers["ChatGPT-Account-Id"], "acct-fake")
        XCTAssertEqual(counts.headers["Authorization"], "Bearer access")
    }

    func testAPersonalPlansBreakdownShowsEveryMeasureOnAUTCDayAndNoModels() async throws {
        let (store, runtime, _, _) = try makeAccount()

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        let last30 = try XCTUnwrap(runtime.usageBreakdown(for: try descriptor(runtime, "last30")))
        XCTAssertEqual(last30.clockNote, "UTC days")
        XCTAssertEqual(last30.totals[.credits] ?? 0, 2_799.42735, accuracy: 1e-6)
        XCTAssertEqual(last30.totals[.turns], 478)
        XCTAssertEqual(last30.totals[.tokens], 2_014_940_056)
        XCTAssertEqual(last30.models, [], "a personal plan reports no credits per model")
        XCTAssertNil(runtime.usageBreakdown(for: try descriptor(runtime, "turns")))
    }

    func testATeamPlanShowsTheChargedCreditsOfTheWorkspaceReportAndRanksModelsByThem() async throws {
        let (store, runtime, http, _) = try makeAccount(planType: "team")

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(rows(store, runtime)["yesterday"], "12.5 credits · 8.1M tokens", "charged credits, not the plan usage")
        XCTAssertEqual(rows(store, runtime)["today"], "0 credits · 0 tokens")
        let breakdown = try XCTUnwrap(requestsFor(http, "daily-workspace-user-token-usage-breakdown"))
        XCTAssertEqual(query(breakdown), ["start_date=2026-10-02", "end_date=2026-10-31", "group_by=day"])
        XCTAssertNil(requestsFor(http, "credit-usage-events"))
        let yesterday = try XCTUnwrap(runtime.usageBreakdown(for: try descriptor(runtime, "yesterday")))
        XCTAssertEqual(yesterday.clockNote, "UTC day")
        XCTAssertEqual(yesterday.modelMeasure, .credits)
        XCTAssertEqual(yesterday.models.map(\.name), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(yesterday.models.map(\.number), [10, 2.5])
    }

    func testAWorkspaceReportWithoutChargedCreditsShowsNoCredits() async throws {
        let (store, runtime, _, _) = try makeAccount(planType: "team", workspaceBreakdown: CodexUsageFixtures.relativeBreakdown)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(rows(store, runtime), [
            "today": "0 tokens", "yesterday": "8.1M tokens", "last30": "2B tokens", "turns": "478 in 30 days"
        ], "relative units never show as credits")
        XCTAssertEqual(runtime.usageBreakdown(for: try descriptor(runtime, "yesterday"))?.models, [])
    }

    func testBusinessEducationAndEnterprisePlansReadTheirChargedCreditsByModel() async throws {
        for planType in ["business", "edu", "enterprise"] {
            let (store, runtime, http, _) = try makeAccount(planType: planType)

            _ = await store.refresh(providerID: runtime.provider.id, force: true)

            let credits = try XCTUnwrap(requestsFor(http, "daily-workspace-user-credit-usage"), planType)
            XCTAssertEqual(query(credits), ["start_date=2026-10-02", "end_date=2026-10-31", "breakdown=model"], planType)
            XCTAssertEqual(rows(store, runtime)["yesterday"], "12.5 credits · 8.1M tokens", planType)
            let yesterday = try XCTUnwrap(runtime.usageBreakdown(for: try descriptor(runtime, "yesterday")))
            XCTAssertEqual(yesterday.models.map(\.name), ["gpt-6-astra", "gpt-6.1-sol"], planType)
        }
    }

    func testADayTheCountsDoNotReportYetShowsNoTokensOrTurnsUntilALaterReadReportsIt() async throws {
        let reportsToday = TestSwitch(false)
        let (store, runtime, _, clock) = try makeAccount(reportsToday: reportsToday)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(rows(store, runtime), [
            "today": "0 credits", "yesterday": "0 credits · 8.1M tokens", "last30": "2.8K credits"
        ], "an unreported day is not a day of zero turns")

        reportsToday.value = true
        clock.set(now.addingTimeInterval(61 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(rows(store, runtime)["today"], "0 credits · 0 tokens")
        XCTAssertEqual(rows(store, runtime)["turns"], "478 in 30 days")
    }

    func testHistoryIsReadOnceAnHourAtOnceOnANewUTCDayAndOnAForcedReread() async throws {
        let (store, runtime, http, clock) = try makeAccount()
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(reportRequests(http).count, 2)

        clock.set(now.addingTimeInterval(30 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(reportRequests(http).count, 2, "an hour has not passed")
        XCTAssertEqual(rows(store, runtime)["yesterday"], "0 credits · 8.1M tokens", "the rows keep the last read")

        clock.set(now.addingTimeInterval(61 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(reportRequests(http).count, 4)

        clock.set(now.addingTimeInterval(62 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true, rereadHourly: true)
        XCTAssertEqual(reportRequests(http).count, 6, "a forced reread reads at once")

        clock.set(Date(timeIntervalSince1970: 1_793_491_500))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(reportRequests(http).count, 8, "a new UTC day is read on the first refresh after midnight")
        let counts = try XCTUnwrap(reportRequests(http).last { $0.url.path.hasSuffix("daily-workspace-usage-counts") })
        XCTAssertEqual(Array(query(counts).prefix(2)), ["start_date=2026-10-31", "end_date=2026-11-01"],
                       "today, and yesterday, which was read before it ended")
    }

    func testAFailedReadHidesTheRowsKeepsTheCardAndWaitsAnHour() async throws {
        let reports = TestSwitch<Int?>(500)
        let (store, runtime, http, clock) = try makeAccount(reports: reports)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), [:])
        XCTAssertEqual(store.data(for: try descriptor(runtime, "weekly")).used, 29)

        reports.value = nil
        clock.set(now.addingTimeInterval(10 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(reportRequests(http).count, 2, "a failed read waits an hour")

        clock.set(now.addingTimeInterval(61 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(rows(store, runtime)["turns"], "478 in 30 days")
    }

    func testTheCreditLimitShowsWhatTheWorkspaceLetsTheMemberSpend() async throws {
        let limit = #"{"source":"workspace_spend_controls","limit":"25000","used":"8000","remaining":"17000","used_percent":32,"remaining_percent":68,"reset_after_seconds":86400,"reset_at":1793520000}"#
        let (store, runtime, _, _) = try makeAccount(planType: "team", individualLimit: limit)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        let data = store.data(for: try descriptor(runtime, "creditLimit"))
        XCTAssertEqual(data.used, 8_000)
        XCTAssertEqual(data.limit, 25_000)
        XCTAssertEqual(data.resetsAt, Date(timeIntervalSince1970: 1_793_520_000))

        let (unlimitedStore, unlimited, _, _) = try makeAccount()
        _ = await unlimitedStore.refresh(providerID: unlimited.provider.id, force: true)
        XCTAssertFalse(unlimitedStore.data(for: try descriptor(unlimited, "creditLimit")).hasData, "a Pro plan has no credit limit")
    }

    private func requestsFor(_ http: RoutingHTTPClient, _ route: String) -> HTTPRequest? {
        reportRequests(http).first { $0.url.path.hasSuffix(route) }
    }
}

final class CodexUsageReportsTests: XCTestCase {
    func testAMalformedDayRejectsTheWholeReport() {
        for body in [
            #"{"data":{}}"#,
            #"{"data":[{"date":"2026-10-30"}]}"#,
            #"{"data":[{"date":"2026-10-30","totals":{"turns":-1}}]}"#,
            #"{"data":[{"date":"2026-10-30","totals":{"turns":3,"text_total_tokens":"lots"}}]}"#,
            #"{"data":[{"totals":{"turns":3}}]}"#
        ] {
            XCTAssertNil(CodexUsageReports.counts(Data(body.utf8)), body)
        }
        XCTAssertNil(CodexUsageReports.creditEvents(Data(#"{"data":[{"date":"2026-10-30","credit_amount":"$5"}]}"#.utf8)))
        XCTAssertNil(CodexUsageReports.workspaceCredits(Data(
            #"{"data":[{"date":"2026-10-30","premium_usage_values":{"credit_usage_credits":{"cli":"lots"}}}]}"#.utf8
        )))
        XCTAssertNil(CodexUsageReports.enterpriseCredits(Data(#"{"data":[{"date":"2026-10-30","values":{"a":"lots"}}]}"#.utf8)))
    }

    func testRecordsForOneDateAddUpAndADateTheCountsLeaveOutHasNoTurns() throws {
        let counts = try XCTUnwrap(CodexUsageReports.counts(Data(#"""
        {"data":[{"date":"2026-10-30","totals":{"turns":10,"text_total_tokens":100}},
                 {"date":"2026-10-30","totals":{"turns":10,"text_total_tokens":100}},
                 {"date":"2026-10-29","totals":{"turns":3,"text_total_tokens":null}}]}
        """#.utf8)))
        let credits = try XCTUnwrap(CodexUsageReports.creditEvents(Data(#"{"data":[{"date":"2026-10-30","credit_amount":-1.5}]}"#.utf8)))

        XCTAssertEqual(CodexUsageReports.day("2026-10-30", counts: counts, credits: credits).totals.values,
                       [.turns: 20, .tokens: 200, .credits: -1.5], "a refund is a reported negative")
        XCTAssertEqual(CodexUsageReports.day("2026-10-29", counts: counts, credits: credits).totals.values, [.turns: 3, .credits: 0])
        XCTAssertEqual(CodexUsageReports.day("2026-10-31", counts: counts, credits: credits).totals.values, [.credits: 0])
    }

    func testAModelWithoutChargedCreditsLeavesOutTheModelList() throws {
        let report = try XCTUnwrap(CodexUsageReports.workspaceCredits(Data(#"""
        {"data":[{"date":"2026-10-30","premium_usage_values":{"credit_usage_credits":{"cli":2.5,"desktop_app":10}},
                  "models":[{"model":"a","credits":9,"on_demand_credits":2},{"model":"b","credits":9}]}]}
        """#.utf8)))

        XCTAssertEqual(report.days["2026-10-30"]?.totals.values, [.credits: 12.5])
        XCTAssertNil(report.days["2026-10-30"]?.byModel)
    }
}
