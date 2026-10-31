import XCTest
@testable import OpenUsage

@MainActor
final class OllamaUsageHistoryTests: XCTestCase {
    /// 20:30 UTC on 30 October, already 31 October in Dubai, so rows read on the local clock would miss.
    nonisolated private static let now = Date(timeIntervalSince1970: 1_793_392_200)
    nonisolated private static let utcToday = 1_793_318_400
    nonisolated private static let balance = #"{"included":{"balance_usd":72.5,"allowance_usd":100}}"#
    private static let historyKeys = ["today", "yesterday", "last30", "requests"]

    /// A day of 4 requests worth $0.25 over two models, today twice that so far, a quiet yesterday, and a
    /// costly day 30 days back that Last 30 Days leaves out. A legacy plan reports request counts only.
    nonisolated private static func usage(_ request: HTTPRequest, legacy: Bool) -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let range = query.first { $0.name == "range" }?.value ?? "7d"
        let days = range == "30d" ? 30 : 7
        let iso = ISO8601DateFormatter()
        func metrics(_ scale: Int, _ parts: (requests: Int, usd: Double, input: Int, cached: Int, output: Int)) -> String {
            let requests = #""request_count":\#(parts.requests * scale)"#
            guard !legacy else { return requests }
            return requests + #","usage_usd":\#(parts.usd * Double(scale)),"input_tokens":\#(parts.input * scale),"#
                + #""cached_input_tokens":\#(parts.cached * scale),"output_tokens":\#(parts.output * scale)"#
        }
        let buckets = (0...days).reversed().map { daysAgo in
            let scale = [0: 2, 1: 0, 30: 400][daysAgo] ?? 1
            let from = Date(timeIntervalSince1970: TimeInterval(utcToday - daysAgo * 86_400))
            let until = daysAgo == 0 ? now : from.addingTimeInterval(86_400)
            let groups = scale == 0 ? "" : #"{"model":"glm-5.3-flash",\#(metrics(scale, (3, 0.2, 2_500, 1_000, 200)))},"#
                + #"{"model":"gpt-oss:120b",\#(metrics(scale, (1, 0.05, 500, 0, 100)))}"#
            return #"{"from":"\#(iso.string(from: from))","until":"\#(iso.string(from: until))",\#(daysAgo == 0 ? #""partial":true,"# : "")"#
                + #"\#(metrics(scale, (4, 0.25, 3_000, 1_000, 300))),"groups":[\#(groups)]}"#
        }
        let start = iso.string(from: Date(timeIntervalSince1970: TimeInterval(utcToday - days * 86_400)))
        let body = #"{"range":"\#(range)","scope":"self","granularity":"day","group_by":"model","from":"\#(start)","#
            + #""until":"\#(iso.string(from: now))","totals":{"request_count":0},"buckets":[\#(buckets.joined(separator: ","))]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    private func makeAccount(
        usage status: TestSwitch<Int?> = TestSwitch(nil), legacy: Bool = false
    ) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient, TestClock) {
        let account = Account(kind: .ollama, label: "Ollama")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("ollama-key"), for: account.id)
        let clock = TestClock(Self.now)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case OllamaUsageClient.balancePath:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.balance.utf8))
            case "/api/usage":
                if let status = status.value { return HTTPResponse(statusCode: status, headers: [:], body: Data()) }
                return Self.usage(request, legacy: legacy)
            default:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"Plan":"pro"}"#.utf8))
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        return (WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now }), runtime, http, clock)
    }

    private func rows(_ store: WidgetDataStore, _ runtime: AccountProviderRuntime) -> [String: String] {
        var rows: [String: String] = [:]
        for descriptor in runtime.widgetDescriptors where Self.historyKeys.contains(descriptor.key) {
            let data = store.data(for: descriptor)
            if data.hasData { rows[descriptor.key] = data.unboundedDetail }
        }
        return rows
    }

    private func usageQueries(_ http: RoutingHTTPClient) -> [String?] {
        http.requests.filter { $0.url.path == "/api/usage" }.map(\.url.query)
    }

    private static let fullRows = [
        "today": "$0.50 · 6.6K tokens",
        "yesterday": "$0 · 0 tokens",
        "last30": "$7.50 · 99K tokens",
        "requests": "120 in 30 days"
    ]

    func testTheRowsShowWhatOllamaReportedForEachUTCDayAndTokensCountCachedInputOnce() async throws {
        let (store, runtime, http, _) = try makeAccount()

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), Self.fullRows)
        XCTAssertEqual(usageQueries(http), ["range=30d&group_by=model"], "one call reads all 30 days")
        let request = try XCTUnwrap(http.requests.first { $0.url.path == "/api/usage" })
        XCTAssertEqual(request.url.host, "ollama.com")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ollama-key")
    }

    func testTodayAndYesterdayAreReadAgainHourlyFromTheLastSevenDaysAndOnCommandR() async throws {
        let (store, runtime, http, clock) = try makeAccount()
        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        clock.set(Self.now.addingTimeInterval(5 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(usageQueries(http).count, 1, "no history read within the hour")
        XCTAssertEqual(rows(store, runtime), Self.fullRows, "the rows keep the last read meanwhile")

        clock.set(Self.now.addingTimeInterval(61 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        clock.set(Self.now.addingTimeInterval(62 * 60))
        _ = await store.refresh(providerIDs: [runtime.provider.id], force: true)

        XCTAssertEqual(usageQueries(http), ["range=30d&group_by=model", "range=7d&group_by=model", "range=7d&group_by=model"])
        XCTAssertEqual(rows(store, runtime), Self.fullRows)
    }

    func testALegacyPlanThatReportsOnlyRequestsShowsOnlyTheRequestsRow() async throws {
        let (store, runtime, _, _) = try makeAccount(legacy: true)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(rows(store, runtime), ["requests": "120 in 30 days"])
    }

    func testAFailedReadHidesTheRowsKeepsTheCardAndWaitsAnHour() async throws {
        let status = TestSwitch<Int?>(500)
        let (store, runtime, http, clock) = try makeAccount(usage: status)

        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), [:])
        let monthly = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "monthly" })
        XCTAssertTrue(store.data(for: monthly).hasData)

        status.value = nil
        clock.set(Self.now.addingTimeInterval(5 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(usageQueries(http).count, 1, "a failed read waits an hour too")

        clock.set(Self.now.addingTimeInterval(61 * 60))
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(usageQueries(http), ["range=30d&group_by=model", "range=30d&group_by=model"], "every day is still unread")
        XCTAssertEqual(rows(store, runtime), Self.fullRows)
    }
}
