import XCTest
@testable import OpenUsage

final class CursorUsageEventsParserTests: XCTestCase {
    /// Shaped like Cursor's `get-filtered-usage-events` page: on-demand events carry what Cursor charged,
    /// and included events carry the value taken from the plan in the same field.
    static let mixedPage = #"""
    {"totalUsageEventsCount":7,"usageEventsDisplay":[
     {"timestamp":"1793000000000","model":"claude-4.6-opus-high-thinking","kind":"USAGE_EVENT_KIND_USAGE_BASED",
      "requestsCosts":30.4,"usageBasedCosts":"$1.25","isTokenBasedCall":true,
      "tokenUsage":{"inputTokens":3,"outputTokens":20525,"cacheWriteTokens":112151,"totalCents":121.41},
      "cursorTokenFee":3.32,"isChargeable":true,"isHeadless":false,"chargedCents":124.73},
     {"timestamp":"1793000001000","model":"composer-2","kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO",
      "usageBasedCosts":"-","tokenUsage":{"inputTokens":3438,"outputTokens":76,"totalCents":40},
      "isChargeable":false,"chargedCents":40},
     {"timestamp":"1793000002000","model":"gpt-5","kind":"USAGE_EVENT_KIND_USAGE_BASED","isChargeable":false,"chargedCents":50},
     {"timestamp":"1793000003000","model":"gpt-5","kind":"USAGE_EVENT_KIND_ERRORED_NOT_CHARGED"},
     {"timestamp":"1793000003500","model":"composer-2","kind":"USAGE_EVENT_KIND_FREE_CREDIT","isChargeable":false,"chargedCents":40},
     {"timestamp":1793000004000,"model":"composer-2","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":"3.5"},
     {"timestamp":"1793000005000","model":"composer-2","kind":"USAGE_EVENT_KIND_USAGE_BASED","isChargeable":true}
    ]}
    """#

    func testOnlyOnDemandEventsCountWhatCursorCharged() throws {
        let page = try XCTUnwrap(CursorUsageEvents.parsePage(Data(Self.mixedPage.utf8)))

        XCTAssertEqual(page.totalCount, 7)
        XCTAssertEqual(page.events.map { $0.totals[.spend] }, [124.73, 0, 0, 0, 0, 3.5, 0].map { $0 / 100 })
        XCTAssertEqual(page.events.first?.date, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(page.events.last?.date, Date(timeIntervalSince1970: 1_793_000_005))
    }

    func testTokensAreEveryKindCursorReportedOnAnyEventKindAndAbsentWithoutTokenUsage() throws {
        let page = try XCTUnwrap(CursorUsageEvents.parsePage(Data(Self.mixedPage.utf8)))

        XCTAssertEqual(page.events.map { $0.totals[.tokens] }, [132_679, 3_514, nil, nil, nil, nil, nil])
        XCTAssertEqual(page.events[0].totals.values, [
            .spend: 124.73 / 100, .usageEvents: 1, .tokens: 132_679,
            .inputTokens: 3, .cacheReadTokens: 0, .cacheWriteTokens: 112_151, .outputTokens: 20_525
        ])
        XCTAssertEqual(page.events.map(\.model), ["claude-4.6-opus-high-thinking", "composer-2", "gpt-5", "gpt-5",
                                                   "composer-2", "composer-2", "composer-2"])

        let day = CursorUsageEvents.day(page.events)
        XCTAssertNil(day.totals[.tokens], "an event without tokenUsage leaves the day's tokens unreported")
        XCTAssertEqual(day.totals[.usageEvents], 7)
        XCTAssertEqual(CursorUsageEvents.day(Array(page.events.prefix(2))).totals[.tokens], 136_193)
        XCTAssertEqual(CursorUsageEvents.day([]).totals, .zero(CursorUsageEvents.measures), "a quiet day is zeros, not a gap")
    }

    func testAnEmptyPageLeavesOutItsEventListButNotItsCount() throws {
        XCTAssertEqual(CursorUsageEvents.parsePage(Data(#"{"totalUsageEventsCount":0}"#.utf8))?.events, [])
        for body in [
            #"{"error":"unauthorized"}"#,
            #"{"usageEventsDisplay":[]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":5}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":-5}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":"$0.05"}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","tokenUsage":{"inputTokens":-1}}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","tokenUsage":"lots"}]}"#
        ] {
            XCTAssertNil(CursorUsageEvents.parsePage(Data(body.utf8)), body)
        }
    }
}

@MainActor
final class CursorUsageHistoryTests: XCTestCase {
    nonisolated private static let accessToken = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "") + ".sig"
    nonisolated private static let usage = #"""
    {"autoBucketModels":["fake-model"],"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,
     "planUsage":{"apiPercentUsed":40,"autoPercentUsed":20,"limit":40000,"remaining":30000,"totalPercentUsed":25},
     "spendLimitUsage":{"individualLimit":50000,"individualRemaining":38000,"limitType":"user"}}
    """#
    nonisolated private static let planInfo = #"{"planInfo":{"planName":"Ultra"}}"#
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    /// Every day holds one on-demand event Cursor charged $1.25 for and one included event worth $9.99 of
    /// plan usage, so only the charge counts.
    nonisolated private static func eventsPage(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body.flatMap(ProviderParse.jsonObject),
              let start = (body["startDate"] as? String).flatMap(Int.init),
              let end = (body["endDate"] as? String).flatMap(Int.init),
              body["page"] as? Int == 1
        else { return HTTPResponse(statusCode: 400, headers: [:], body: Data()) }
        let timestamp = min(start + 3_600_000, end)
        let page = """
        {"totalUsageEventsCount":2,"usageEventsDisplay":[
         {"timestamp":"\(timestamp)","model":"claude-4.6-opus","kind":"USAGE_EVENT_KIND_USAGE_BASED","isChargeable":true,
          "chargedCents":125,"tokenUsage":{"inputTokens":3,"outputTokens":200,"totalCents":120}},
         {"timestamp":"\(timestamp)","model":"composer-2","kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","isChargeable":false,
          "chargedCents":999,"tokenUsage":{"inputTokens":3000,"outputTokens":100,"totalCents":999}}]}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(page.utf8))
    }

    private func makeAccount(
        events: TestSwitch<Int?>, retryAfter: String? = nil, clock: TestClock? = nil
    ) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .cursor, label: "Cursor")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: Self.accessToken, refreshToken: "refresh")), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case CursorUsageClient.usageURL.path:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.usage.utf8))
            case CursorUsageClient.planURL.path:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.planInfo.utf8))
            case CursorUsageClient.usageEventsURL.path:
                if let status = events.value {
                    return HTTPResponse(statusCode: status, headers: retryAfter.map { ["retry-after": $0] } ?? [:], body: Data())
                }
                return Self.eventsPage(request)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let clock = clock ?? TestClock(now)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        return (WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now }), runtime, http)
    }

    private func spend(_ store: WidgetDataStore, _ runtime: AccountProviderRuntime) -> [String: Double] {
        var spend: [String: Double] = [:]
        for descriptor in runtime.widgetDescriptors where ["today", "yesterday", "last30"].contains(descriptor.key) {
            let widget = store.data(for: descriptor)
            if widget.hasData { spend[widget.title] = widget.values.first?.number }
        }
        return spend
    }

    private func eventRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url == CursorUsageClient.usageEventsURL }
    }

    func testTheRowsShowWhatCursorChargedForOnDemandUsageAndNoEstimate() async throws {
        let (store, runtime, http) = try makeAccount(events: TestSwitch(nil))

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(spend(store, runtime), ["Today": 1.25, "Yesterday": 1.25, "Last 30 Days": 37.5])
        let requests = eventRequests(http)
        XCTAssertEqual(requests.count, 30, "one page for each of the 30 days")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_fake%3A%3A\(Self.accessToken)")
        XCTAssertEqual(request.headers["Origin"], "https://cursor.com")
    }

    func testALaterRefreshRereadsOnlyTodayAndYesterday() async throws {
        let (store, runtime, http) = try makeAccount(events: TestSwitch(nil))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        let firstRead = eventRequests(http).count

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(eventRequests(http).count - firstRead, 2)
        XCTAssertEqual(spend(store, runtime), ["Today": 1.25, "Yesterday": 1.25, "Last 30 Days": 37.5])
    }

    func testAFailedRereadHidesTheRowsInsteadOfAnOldValueAndNeverBreaksTheCard() async throws {
        let events = TestSwitch<Int?>(500)
        let (store, runtime, _) = try makeAccount(events: events)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(spend(store, runtime), [:], "nothing read yet, so no row claims a value")
        let totalUsage = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "usage" })
        XCTAssertEqual(store.data(for: totalUsage).used, 25)

        events.value = nil
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        events.value = 503
        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(spend(store, runtime), [:], "today and yesterday went unread, so no row shows an old value")
    }

    func testARateLimitStopsTheSweepAndWaitsForRetryAfterOrAnHour() async throws {
        for (retryAfter, wait) in [("120", 120.0), (nil, 3600.0)] {
            let events = TestSwitch<Int?>(429)
            let clock = TestClock(now)
            let (store, runtime, http) = try makeAccount(events: events, retryAfter: retryAfter, clock: clock)

            _ = await store.refresh(providerID: runtime.provider.id, force: true)
            let firstSweep = eventRequests(http).count
            XCTAssertLessThanOrEqual(firstSweep, 4, "the sweep stops at the 429 instead of asking for all 30 days")

            events.value = nil
            clock.set(now.addingTimeInterval(wait - 1))
            _ = await store.refresh(providerID: runtime.provider.id, force: true)
            XCTAssertEqual(eventRequests(http).count, firstSweep, "no history read before the wait ends")
            XCTAssertEqual(spend(store, runtime), [:])

            clock.set(now.addingTimeInterval(wait + 1))
            _ = await store.refresh(providerID: runtime.provider.id, force: true)
            XCTAssertEqual(eventRequests(http).count - firstSweep, 30, "every unread day is still due")
            XCTAssertEqual(spend(store, runtime), ["Today": 1.25, "Yesterday": 1.25, "Last 30 Days": 37.5])
        }
    }

    func testTheRowsAddTheTokensCursorReportedAndTheUsageEventsRowCountsEveryEvent() async throws {
        let (store, runtime, _) = try makeAccount(events: TestSwitch(nil))

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        var rows: [String: String] = [:]
        for descriptor in runtime.widgetDescriptors where descriptor.historyRow != nil {
            let data = store.data(for: descriptor)
            if data.hasData { rows[descriptor.key] = data.unboundedDetail }
        }
        XCTAssertEqual(rows, [
            "today": "$1.25 · 3.3K tokens",
            "yesterday": "$1.25 · 3.3K tokens",
            "last30": "$37.50 · 99.1K tokens",
            "usageEvents": "60 in 30 days"
        ])
    }

    func testEachWindowRowHasABreakdownOfWhatCursorReportedAndTheUsageEventsRowHasNone() async throws {
        let (store, runtime, _) = try makeAccount(events: TestSwitch(nil))
        let descriptor = { (key: String) in try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == key }) }
        XCTAssertNil(runtime.usageBreakdown(for: try descriptor("today")), "nothing read yet")

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        let today = try XCTUnwrap(runtime.usageBreakdown(for: try descriptor("today")))
        XCTAssertEqual(today.window, .today)
        XCTAssertEqual(today.totals.values, [
            .spend: 1.25, .usageEvents: 2, .tokens: 3_303,
            .inputTokens: 3_003, .cacheReadTokens: 0, .cacheWriteTokens: 0, .outputTokens: 300
        ])
        XCTAssertEqual(today.models.map(\.name), ["composer-2", "claude-4.6-opus"])
        XCTAssertEqual(today.models.map(\.number), [3_100, 203])
        XCTAssertEqual(today.modelMeasure, .tokens)
        XCTAssertEqual(runtime.usageBreakdown(for: try descriptor("last30"))?.totals[.usageEvents], 60)
        XCTAssertNotNil(runtime.usageBreakdown(for: try descriptor("yesterday")))
        XCTAssertNil(runtime.usageBreakdown(for: try descriptor("usageEvents")))
    }
}
final class CursorHistorySourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        return calendar
    }()
    private let accessToken = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "") + ".sig"

    private var span: [Date] { UsageHistory.dayStarts(0..<30, now: now, calendar: calendar) }

    private func source(_ http: RoutingHTTPClient) -> CursorHistorySource {
        CursorHistorySource(client: CursorUsageClient(http: http), accessToken: accessToken, accountID: "cursor@1")
    }

    private static func page(_ request: HTTPRequest) -> (start: Int, page: Int) {
        let body = request.body.flatMap(ProviderParse.jsonObject) ?? [:]
        return ((body["startDate"] as? String).flatMap(Int.init) ?? 0, body["page"] as? Int ?? 0)
    }

    private static func events(total: Int, at milliseconds: Int, cents: [Double]) -> HTTPResponse {
        let events = cents.map { #"{"timestamp":"\#(milliseconds)","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":\#($0)}"# }
        let body = #"{"totalUsageEventsCount":\#(total),"usageEventsDisplay":[\#(events.joined(separator: ","))]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    @MainActor
    func testADayOverSeveralPagesCountsEveryPageAndAShortPageFailsTheDay() async {
        let span = span
        let short = Int(span[2].timeIntervalSince1970 * 1000)
        let http = RoutingHTTPClient { request in
            let (start, page) = Self.page(request)
            if start == short { return Self.events(total: 3, at: start + 1, cents: page == 1 ? [100, 100] : []) }
            return Self.events(total: 3, at: start + 1, cents: page == 1 ? [100, 100] : [25.5])
        }
        var source = source(http)
        source.pageSize = 2

        let days = await source.read(span, asOf: now, calendar: calendar).days

        XCTAssertEqual(days.count, 29)
        XCTAssertNil(days[span[2]], "a page that ends before the count leaves the day unread")
        XCTAssertEqual(days[span[0]]?.totals[.spend] ?? 0, 2.255, accuracy: 1e-9)
        XCTAssertEqual(days[span[1]]?.totals[.spend] ?? 0, 2.255, accuracy: 1e-9)
        let history = UsageHistory(calendar: calendar, asOf: now, days: days)
        let cursor = AccountProviderRuntime(account: Account(kind: .cursor, label: "Cursor"), vault: InMemoryCredentialVault())
        XCTAssertEqual(HistoryRow.lines(for: cursor.widgetDescriptors, in: history).map(\.label), ["Today", "Yesterday"])
    }

    func testTheTimeBudgetKeepsTheDaysThatFinished() async {
        let span = span
        let today = Int(span[0].timeIntervalSince1970 * 1000)
        let http = RoutingHTTPClient { request in
            let (start, _) = Self.page(request)
            if start != today { try await Task.sleep(for: .seconds(30)) }
            return Self.events(total: 1, at: start + 1, cents: [7])
        }
        var source = source(http)
        source.budget = 0.5
        var ledger = UsageLedger()
        ledger.record([span[9]: UsageDay(totals: UsageTotals(values: [.spend: 0.03]))], due: [span[9]], span: span)

        let due = ledger.due(span)
        ledger.record(await source.read(due, asOf: now, calendar: calendar).days, due: due, span: span)

        XCTAssertEqual(due.count, 29, "a day read before is not read again")
        XCTAssertEqual(ledger.days.mapValues { $0.totals[.spend] }, [span[0]: 0.07, span[9]: 0.03])
    }

    func testADayThatStartsAtOneOClockIsReadToTheNextMidnight() async throws {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let september6 = Date(timeIntervalSince1970: 1_788_667_200)
        let http = RoutingHTTPClient { _ in Self.events(total: 0, at: 0, cents: []) }

        let days = await source(http).read([september6], asOf: Date(timeIntervalSince1970: 1_788_793_200), calendar: santiago).days

        XCTAssertNotNil(days[september6])
        let body = try XCTUnwrap(http.requests.first?.body.flatMap(ProviderParse.jsonObject))
        XCTAssertEqual(body["endDate"] as? String, "1788749999999", "a 23-hour day ends at Sep 7 00:00, not 01:00")
    }

    func testADayLastReadWhileItWasTodayIsReadAgainAfterAGapOfDays() {
        let friday = span
        let monday = UsageHistory.dayStarts(0..<30, now: now.addingTimeInterval(3 * 86_400), calendar: calendar)
        let partial = UsageDay(totals: UsageTotals(values: [.spend: 1]))
        let full = UsageDay(totals: UsageTotals(values: [.spend: 4]))
        var ledger = UsageLedger()
        ledger.record([friday[0]: partial, friday[1]: full], due: ledger.due(friday), span: friday)

        let due = ledger.due(monday)

        XCTAssertTrue(due.contains(friday[0]), "Friday was read before it ended")
        XCTAssertFalse(due.contains(friday[1]), "Thursday was read after it ended")
        ledger.record([friday[0]: full], due: [friday[0]], span: monday)
        XCTAssertEqual(ledger.days[friday[0]], full)
        XCTAssertFalse(ledger.due(monday).contains(friday[0]))
    }
}
