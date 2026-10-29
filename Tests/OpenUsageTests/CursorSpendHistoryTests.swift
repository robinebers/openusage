import XCTest
@testable import OpenUsage

final class CursorUsageEventsParserTests: XCTestCase {
    /// Shaped like Cursor's `get-filtered-usage-events` page: on-demand events carry what Cursor charged,
    /// and included events carry the value taken from the plan in the same field.
    static let mixedPage = #"""
    {"totalUsageEventsCount":6,"usageEventsDisplay":[
     {"timestamp":"1793000000000","model":"claude-4.6-opus-high-thinking","kind":"USAGE_EVENT_KIND_USAGE_BASED",
      "requestsCosts":30.4,"usageBasedCosts":"$1.25","isTokenBasedCall":true,
      "tokenUsage":{"inputTokens":3,"outputTokens":20525,"cacheWriteTokens":112151,"totalCents":121.41},
      "cursorTokenFee":3.32,"isChargeable":true,"isHeadless":false,"chargedCents":124.73},
     {"timestamp":"1793000001000","model":"composer-2","kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO",
      "usageBasedCosts":"-","tokenUsage":{"inputTokens":3438,"outputTokens":76,"totalCents":40},
      "isChargeable":false,"chargedCents":40},
     {"timestamp":"1793000002000","model":"gpt-5","kind":"USAGE_EVENT_KIND_USAGE_BASED","isChargeable":false,"chargedCents":50},
     {"timestamp":"1793000003000","model":"gpt-5","kind":"USAGE_EVENT_KIND_ERRORED_NOT_CHARGED"},
     {"timestamp":1793000004000,"model":"composer-2","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":"3.5"},
     {"timestamp":"1793000005000","model":"composer-2","kind":"USAGE_EVENT_KIND_USAGE_BASED","isChargeable":true}
    ]}
    """#

    func testOnlyOnDemandEventsCountWhatCursorCharged() throws {
        let page = try XCTUnwrap(CursorUsageEvents.parsePage(Data(Self.mixedPage.utf8)))

        XCTAssertEqual(page.totalCount, 6)
        XCTAssertEqual(page.events.map(\.chargedCents), [124.73, 0, 0, 0, 3.5, 0])
        XCTAssertEqual(page.events.first?.date, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(page.events.last?.date, Date(timeIntervalSince1970: 1_793_000_005))
    }

    func testAnEmptyPageLeavesOutItsEventListButNotItsCount() throws {
        XCTAssertEqual(CursorUsageEvents.parsePage(Data(#"{"totalUsageEventsCount":0}"#.utf8))?.events, [])
        for body in [
            #"{"error":"unauthorized"}"#,
            #"{"usageEventsDisplay":[]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":5}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":-5}]}"#,
            #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"1","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":"$0.05"}]}"#
        ] {
            XCTAssertNil(CursorUsageEvents.parsePage(Data(body.utf8)), body)
        }
    }
}

@MainActor
final class CursorSpendHistoryTests: XCTestCase {
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

    private func makeAccount(events: TestSwitch<Int?>) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient) {
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
                if let status = events.value { return HTTPResponse(statusCode: status, headers: [:], body: Data()) }
                return Self.eventsPage(request)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let now = self.now
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { now })
        return (WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { now }), runtime, http)
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

    func testAFailedReadKeepsTheDaysAlreadyReadAndNeverBreaksTheCard() async throws {
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
        XCTAssertEqual(spend(store, runtime), ["Today": 1.25, "Yesterday": 1.25, "Last 30 Days": 37.5])
    }
}

final class CursorSpendHistoryFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        return calendar
    }()
    private let accessToken = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "") + ".sig"

    private static func page(_ request: HTTPRequest) -> (start: Int, page: Int) {
        let body = request.body.flatMap(ProviderParse.jsonObject) ?? [:]
        return ((body["startDate"] as? String).flatMap(Int.init) ?? 0, body["page"] as? Int ?? 0)
    }

    private static func events(total: Int, at milliseconds: Int, cents: [Double]) -> HTTPResponse {
        let events = cents.map { #"{"timestamp":"\#(milliseconds)","kind":"USAGE_EVENT_KIND_USAGE_BASED","chargedCents":\#($0)}"# }
        let body = #"{"totalUsageEventsCount":\#(total),"usageEventsDisplay":[\#(events.joined(separator: ","))]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func testADayOverSeveralPagesCountsEveryPageAndAShortPageFailsTheDay() async {
        let window = CursorSpendHistoryFetcher.window(now: now, calendar: calendar)
        let short = Int(window[2].start.timeIntervalSince1970 * 1000)
        let http = RoutingHTTPClient { request in
            let (start, page) = Self.page(request)
            if start == short { return Self.events(total: 3, at: start + 1, cents: page == 1 ? [100, 100] : []) }
            return Self.events(total: 3, at: start + 1, cents: page == 1 ? [100, 100] : [25.5])
        }
        let fetcher = CursorSpendHistoryFetcher(client: CursorUsageClient(http: http), pageSize: 2)

        let days = await fetcher.refresh([:], window: window, accessToken: accessToken, calendar: calendar, accountID: "cursor@1")

        XCTAssertEqual(days.count, 29)
        XCTAssertNil(days[window[2].start], "a page that ends before the count leaves the day unread")
        XCTAssertEqual(days[window[0].start], CursorSpendDay(chargedCents: 225.5, isComplete: false))
        XCTAssertEqual(days[window[1].start], CursorSpendDay(chargedCents: 225.5, isComplete: true))
        XCTAssertEqual(CursorUsageEvents.spendLines(days, window: window.map(\.start)).map(\.label), ["Today", "Yesterday"])
    }

    func testTheTimeBudgetKeepsTheDaysThatFinished() async {
        let window = CursorSpendHistoryFetcher.window(now: now, calendar: calendar)
        let today = Int(window[0].start.timeIntervalSince1970 * 1000)
        let http = RoutingHTTPClient { request in
            let (start, _) = Self.page(request)
            if start != today { try await Task.sleep(for: .seconds(30)) }
            return Self.events(total: 1, at: start + 1, cents: [7])
        }
        let fetcher = CursorSpendHistoryFetcher(client: CursorUsageClient(http: http), budget: 0.5)
        let stored = [window[9].start: CursorSpendDay(chargedCents: 3, isComplete: true)]

        let days = await fetcher.refresh(stored, window: window, accessToken: accessToken, calendar: calendar, accountID: "cursor@1")

        XCTAssertEqual(days, [window[0].start: CursorSpendDay(chargedCents: 7, isComplete: false),
                              window[9].start: CursorSpendDay(chargedCents: 3, isComplete: true)])
    }
}
