import Foundation
import XCTest
@testable import OpenUsage

final class CursorUsageEventsParserTests: XCTestCase {
    func testParsesTokenBucketsTimestampsAndRejectedEvents() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "totalUsageEventsCount": 5,
            "usageEventsDisplay": [
                [
                    "timestamp": "1800000000123",
                    "model": "  composer-1 \n",
                    "tokenUsage": [
                        "inputTokens": 11,
                        "outputTokens": 17,
                        "cacheWriteTokens": 13,
                        "cacheReadTokens": 19
                    ]
                ],
                [
                    "timestamp": 1_800_000_001_234 as NSNumber,
                    "model": " \n"
                ],
                ["timestamp": "not-a-date", "model": "composer-3"],
                [
                    "timestamp": "1800000000123",
                    "model": "composer-4",
                    "tokenUsage": ["inputTokens": -1]
                ],
                [
                    "timestamp": "1800000000123",
                    "model": "composer-5",
                    "tokenUsage": ["outputTokens": 1.5]
                ]
            ]
        ])

        let page = try CursorUsageEvents.parsePage(data)

        XCTAssertEqual(page.totalCount, 5)
        XCTAssertEqual(page.rejectedEventCount, 3)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events[0].model, "composer-1")
        XCTAssertEqual(page.events[0].tokens, TokenBreakdown(input: 11, cacheWrite5m: 13, cacheRead: 19, output: 17))
        XCTAssertEqual(page.events[0].date, Date(timeIntervalSince1970: 1_800_000_000.123))
        XCTAssertEqual(page.events[1].model, "")
        XCTAssertEqual(page.events[1].tokens, TokenBreakdown())
        XCTAssertEqual(page.events[1].date, Date(timeIntervalSince1970: 1_800_000_001.234))
    }

    func testRequiresValidPageShapeAndTotalCount() throws {
        let missingTotal = try JSONSerialization.data(withJSONObject: ["usageEventsDisplay": []])
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(missingTotal)) { error in
            XCTAssertEqual(error as? CursorUsageEventsError, .invalidResponse)
        }
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? CursorUsageEventsError, .invalidResponse)
        }
    }
}

final class CursorUsageEventsClientTests: XCTestCase {
    func testFetchUsageEventsPageBuildsPOSTRequest() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)

        let response = try await CursorUsageClient(http: http).fetchUsageEventsPage(
            accessToken: accessToken,
            start: start,
            end: end,
            page: 3,
            pageSize: 1000
        )

        XCTAssertEqual(response?.statusCode, 200)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CursorUsageClient.usageEventsURL)
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Origin"], "https://cursor.com")
        XCTAssertEqual(request.timeout, 15)
        let body = try XCTUnwrap(request.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["startDate"] as? String, "1000000")
        XCTAssertEqual(payload["endDate"] as? String, "2000000")
        XCTAssertEqual((payload["page"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((payload["pageSize"] as? NSNumber)?.intValue, 1000)
    }

    func testNoSessionSkipsTheRequest() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }

        let result = try await CursorUsageClient(http: http).fetchUsageEventsPage(
            accessToken: makeCursorJWT(sub: nil),
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            page: 1,
            pageSize: 1000
        )

        XCTAssertNil(result)
        XCTAssertTrue(http.requests.isEmpty)
    }
}

@MainActor
final class CursorUsageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let userID = "cursor-history-user"
    private let token = makeCursorJWT(sub: "google-oauth2|cursor-history-user")

    func testBackfillPublishesThirtyDaysOfSpendAndWritesTheCache() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            let event = CursorHistoryTestData.event(
                on: params.start,
                model: "composer-1",
                input: 10_000
            )
            return try CursorHistoryTestData.page(total: 1, events: params.page == 1 ? [event] : [])
        }
        let provider = makeProvider(http: http, store: store, now: now)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        XCTAssertEqual(snapshot.usageHistory?.series.daily.count, 30)
        XCTAssertEqual(
            Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
            Set(dayStarts.map { $0.key })
        )

        let dailyCost = try XCTUnwrap(TestPricing.bundled.estimatedCostDollars(
            model: "composer-1",
            tokens: TokenBreakdown(input: 10_000),
            applyLongContextRates: false
        ))
        let expectedThirtyDayCost = ((dailyCost * 100).rounded() / 100) * 30
        XCTAssertEqual(
            try XCTUnwrap(values(snapshot.lines, "Last 30 Days")?.first?.number),
            expectedThirtyDayCost,
            accuracy: 0.000_001
        )
        let savedDays = store.load(userID: userID, timeZone: Calendar.current.timeZone.identifier)
        XCTAssertEqual(savedDays.count, 30)
        XCTAssertFalse(try XCTUnwrap(savedDays[dayStarts[0].key]).isComplete)
        XCTAssertTrue(try XCTUnwrap(savedDays[dayStarts[1].key]).isComplete)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasSuffix(".json") })
    }

    func testIncrementalRefreshOnlyRequestsTodayAndYesterday() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let cachedDays = cachedHistory(now: now)
        store.save(cachedDays, userID: userID, timeZone: Calendar.current.timeZone.identifier)
        let http = historyHTTP { request in
            guard CursorHistoryTestData.parameters(request) != nil else {
                return CursorHistoryTestData.invalidRequest
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
                       Set(dayStarts(now: now).prefix(2).map { $0.key }))
        XCTAssertEqual(history?.count, 30)
        let unchangedOlderDay = try XCTUnwrap(history?.first { $0.dayStart == dayStarts(now: now)[2].start })
        XCTAssertEqual(unchangedOlderDay.day.models["composer-1"]?.input, 2_002)
    }

    func testRefetchesIncompleteOlderDayAndPublishesFinalizedTotals() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let incompleteDay = dayStarts[5]
        var cachedDays = cachedHistory(now: now)
        cachedDays[incompleteDay.key] = CursorUsageDay(
            models: ["composer-1": TokenBreakdown(input: 100)],
            isComplete: false
        )
        store.save(cachedDays, userID: userID, timeZone: Calendar.current.timeZone.identifier)
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            guard params.startKey == incompleteDay.key else {
                return try CursorHistoryTestData.page(total: 0, events: [])
            }
            let event = CursorHistoryTestData.event(on: params.start, model: "composer-1", input: 900)
            return try CursorHistoryTestData.page(total: 1, events: params.page == 1 ? [event] : [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(
            Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
            Set([dayStarts[0].key, dayStarts[1].key, incompleteDay.key])
        )
        let publishedDay = try XCTUnwrap(history?.first { $0.dayStart == incompleteDay.start })
        XCTAssertEqual(publishedDay.day.models["composer-1"]?.input, 900)
        XCTAssertTrue(publishedDay.day.isComplete)
        let savedDay = try XCTUnwrap(
            store.load(userID: userID, timeZone: Calendar.current.timeZone.identifier)[incompleteDay.key]
        )
        XCTAssertEqual(savedDay.models["composer-1"]?.input, 900)
        XCTAssertTrue(savedDay.isComplete)
    }

    func testIncompleteSecondPageKeepsPreviouslyCachedDayAndPublishesHistory() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let days = dayStarts(now: now)
        let todayKey = days[0].key
        var cachedDays = cachedHistory(now: now)
        cachedDays[todayKey] = CursorUsageDay(
            models: ["composer-1": TokenBreakdown(input: 2_000)],
            isComplete: false
        )
        store.save(cachedDays, userID: userID, timeZone: Calendar.current.timeZone.identifier)
        let cachedDaysForResponses = cachedDays
        let pageOneEvents = (0..<1000).map { _ in
            CursorHistoryTestData.event(on: days[0].start, model: "composer-1", input: 1)
        }
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            if params.startKey == todayKey {
                return try CursorHistoryTestData.page(total: 1500, events: params.page == 1 ? pageOneEvents : [])
            }
            let existing = cachedDaysForResponses[params.startKey]?.models["composer-1"]?.input ?? 0
            let events = existing > 0
                ? [CursorHistoryTestData.event(on: params.start, model: "composer-1", input: existing)]
                : []
            return try CursorHistoryTestData.page(total: events.count, events: events)
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(http.requests.filter { CursorHistoryTestData.parameters($0)?.startKey == todayKey }.count, 2)
        XCTAssertEqual(history?.count, 30)
        XCTAssertEqual(history?.first?.day.models["composer-1"]?.input, 2_000)
        let savedToday = store.load(userID: userID, timeZone: Calendar.current.timeZone.identifier)[todayKey]
        XCTAssertEqual(savedToday?.models["composer-1"]?.input, 2_000)
        XCTAssertEqual(savedToday?.isComplete, false)
        XCTAssertEqual(history?.first(where: { $0.dayStart == dayStarts(now: now)[2].start })?.day.models["composer-1"]?.input, 2_002)
    }

    func testDeadlineKeepsFastDaysAndNextRefreshCompletesBackfill() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let nowStart = Calendar.current.startOfDay(for: now)
        let slowHTTP = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            let age = Calendar.current.dateComponents([.day], from: params.start, to: nowStart).day ?? 0
            if age > 10 {
                try await Task.sleep(for: .seconds(5))
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let provider = makeProvider(http: slowHTTP, store: store, now: now, budget: 0.3)

        let clock = ContinuousClock()
        let started = clock.now
        let firstSnapshot = await provider.refresh()
        let elapsed = started.duration(to: clock.now)
        let persistedAfterDeadline = store.load(userID: userID, timeZone: Calendar.current.timeZone.identifier)
        XCTAssertTrue(firstSnapshot.lines.contains { $0.label == "Total usage" }, "live plan usage must survive spend-history timeout")
        XCTAssertNil(firstSnapshot.usageHistory)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertGreaterThan(persistedAfterDeadline.count, 0)
        XCTAssertLessThan(persistedAfterDeadline.count, 30)

        let fastHTTP = historyHTTP { _ in
            try CursorHistoryTestData.page(total: 0, events: [])
        }
        let secondProvider = makeProvider(http: fastHTTP, store: store, now: now, budget: 2)
        let secondSnapshot = await secondProvider.refresh()
        let requestedKeys = Set(fastHTTP.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey })
        let expectedKeys = Set(dayStarts(now: now).filter { day in
            day.key == dayStarts(now: now)[0].key || day.key == dayStarts(now: now)[1].key || persistedAfterDeadline[day.key] == nil
        }.map { $0.key })

        XCTAssertEqual(requestedKeys, expectedKeys)
        XCTAssertNotNil(secondSnapshot.usageHistory)
        XCTAssertEqual(secondSnapshot.usageHistory?.series.daily.count, 0)
    }

    func testAccountCacheIsolation() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        store.save(cachedHistory(now: now), userID: "account-a", timeZone: Calendar.current.timeZone.identifier)
        let http = historyHTTP { _ in
            try CursorHistoryTestData.page(total: 0, events: [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let result = await fetcher.refresh(
            accessToken: makeCursorJWT(sub: "google-oauth2|account-b"),
            userID: "account-b",
            now: now
        )

        XCTAssertEqual(http.requests.count, 30)
        XCTAssertEqual(result?.count, 30)
        XCTAssertEqual(store.load(userID: "account-a", timeZone: Calendar.current.timeZone.identifier).count, 30)
        XCTAssertEqual(store.load(userID: "account-b", timeZone: Calendar.current.timeZone.identifier).count, 30)
    }

    func testHTTPFailureLeavesMissingDayUnstoredAndKeepsExistingFileUnchanged() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let todayKey = dayStarts[0].key
        let missingDayHTTP = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            if params.startKey == todayKey {
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let fetcher = makeFetcher(http: missingDayHTTP, store: store)

        let incomplete = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertNil(incomplete)
        let partial = store.load(userID: userID, timeZone: Calendar.current.timeZone.identifier)
        XCTAssertNil(partial[todayKey])
        XCTAssertEqual(partial.count, 29)

        let cached = cachedHistory(now: now)
        store.save(cached, userID: userID, timeZone: Calendar.current.timeZone.identifier)
        let fileURL = try XCTUnwrap((try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )).first)
        let originalFile = try Data(contentsOf: fileURL)
        let failedRefreshHTTP = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request),
                  params.startKey == dayStarts[0].key || params.startKey == dayStarts[1].key
            else {
                return CursorHistoryTestData.invalidRequest
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let failedRefresh = makeFetcher(http: failedRefreshHTTP, store: store)

        let retained = await failedRefresh.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(retained?.count, 30)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalFile)
    }

    private func makeStore() -> (CursorUsageHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-history-tests-\(UUID().uuidString)", isDirectory: true)
        return (CursorUsageHistoryStore(directory: directory), directory)
    }

    private func makeProvider(
        http: RoutingHTTPClient,
        store: CursorUsageHistoryStore,
        now: Date,
        budget: TimeInterval = 20
    ) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: token]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled },
            spendHistoryBudget: budget,
            usageHistoryStore: store
        )
    }

    private func makeFetcher(http: RoutingHTTPClient, store: CursorUsageHistoryStore) -> CursorSpendHistoryFetcher {
        CursorSpendHistoryFetcher(client: CursorUsageClient(http: http), store: store, budget: 20)
    }

    private func historyHTTP(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            if request.url == CursorUsageClient.usageEventsURL {
                return try await handler(request)
            }
            if request.url == CursorUsageClient.usageURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}
                """.utf8))
            }
            if request.url == CursorUsageClient.planURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if request.url == CursorUsageClient.creditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func dayStarts(now: Date) -> [(key: String, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<30).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (DailyUsageAccumulator.dayKey(from: start, calendar: calendar), start)
        }
    }

    private func cachedHistory(now: Date) -> [String: CursorUsageDay] {
        Dictionary(uniqueKeysWithValues: dayStarts(now: now).enumerated().map { index, day in
            (
                day.key,
                CursorUsageDay(models: ["composer-1": TokenBreakdown(input: 2_000 + index)], isComplete: true)
            )
        })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

private struct CursorHistoryRequest: Sendable {
    var start: Date
    var startKey: String
    var page: Int
}

private struct CursorHistoryEvent: Sendable {
    var timestampMilliseconds: Int
    var model: String
    var input: Int
}

private enum CursorHistoryTestData {
    static let invalidRequest = HTTPResponse(statusCode: 400, headers: [:], body: Data())

    static func parameters(_ request: HTTPRequest) -> CursorHistoryRequest? {
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let startString = payload["startDate"] as? String,
              let milliseconds = Int(startString),
              let page = (payload["page"] as? NSNumber)?.intValue
        else {
            return nil
        }
        let start = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return CursorHistoryRequest(
            start: start,
            startKey: DailyUsageAccumulator.dayKey(from: start, calendar: .current),
            page: page
        )
    }

    static func event(on dayStart: Date, model: String, input: Int) -> CursorHistoryEvent {
        CursorHistoryEvent(
            timestampMilliseconds: Int(dayStart.timeIntervalSince1970 * 1000),
            model: model,
            input: input
        )
    }

    static func page(total: Int, events: [CursorHistoryEvent]) throws -> HTTPResponse {
        let response: [String: Any] = [
            "totalUsageEventsCount": total,
            "usageEventsDisplay": events.map { event in
                [
                    "timestamp": String(event.timestampMilliseconds),
                    "model": event.model,
                    "tokenUsage": ["inputTokens": event.input]
                ]
            }
        ]
        return HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: response)
        )
    }
}
