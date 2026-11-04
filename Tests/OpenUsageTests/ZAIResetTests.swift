import XCTest
@testable import OpenUsage

@MainActor
final class ZAIResetTests: XCTestCase {
    /// 2026-11-04 00:00 UTC.
    private nonisolated static let now = Date(timeIntervalSince1970: 1_793_750_400)
    private nonisolated static let quota = #"""
    {"code":200,"data":{"limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":64,"nextResetTime":1793760000000},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":38,"nextResetTime":1794100000000}
    ]},"success":true}
    """#

    /// Session record 11 and Weekly record 21 share an expiry; 13 is spent and 14 has expired.
    private nonisolated static let list = #"""
    {"code":200,"success":true,"data":{
      "fiveHourResets":[
        {"recordId":12,"available":true,"expireTime":"2026-11-10 08:00:00"},
        {"recordId":11,"available":true,"expireTime":"2026-11-06 20:00:00"},
        {"recordId":13,"available":false,"expireTime":"2026-11-07 08:00:00"},
        {"recordId":14,"available":true,"expireTime":"2026-11-03 08:00:00"}
      ],
      "weekResets":[{"recordId":21,"available":true,"expireTime":"2026-11-06 20:00:00"}]
    }}
    """#

    private nonisolated static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private nonisolated static let session11 = ZAIReset(window: .fiveHour, recordID: 11, expiresAt: utc("2026-11-06T12:00:00Z"))
    private nonisolated static let weekly21 = ZAIReset(window: .week, recordID: 21, expiresAt: utc("2026-11-06T12:00:00Z"))
    private nonisolated static let session12 = ZAIReset(window: .fiveHour, recordID: 12, expiresAt: utc("2026-11-10T00:00:00Z"))

    func testListKeepsAvailableUnexpiredResetsOfBothWindowsEarliestFirstInUTCPlus8() throws {
        let resets = try ZAIResetsMapper.resets(from: Data(Self.list.utf8), now: Self.now)
        XCTAssertEqual(resets, [Self.session11, Self.weekly21, Self.session12])
    }

    func testListRejectsAnUnreadableRecordOrAFailedAnswer() {
        for body in [
            #"{"success":true,"data":{"fiveHourResets":[{"recordId":1,"available":true,"expireTime":"2026-11-06T20:00:00Z"}]}}"#,
            #"{"success":true,"data":{"weekResets":[{"available":true,"expireTime":"2026-11-06 20:00:00"}]}}"#,
            #"{"success":false,"msg":"error","data":null}"#
        ] {
            XCTAssertThrowsError(try ZAIResetsMapper.resets(from: Data(body.utf8), now: Self.now), body)
        }
    }

    func testDetailListsEachWindowApartAndKeysEqualExpiriesApart() {
        let windows = RateLimitResetsDetail.windows([Self.session11, Self.weekly21, Self.session12], now: Self.now)
        XCTAssertEqual(windows.map(\.window), [.fiveHour, .week])
        XCTAssertEqual(windows.map { $0.resets.map(\.recordID) }, [[11, 12], [21]])
        XCTAssertNotEqual(windows[0].entries[0].key, windows[1].entries[0].key, "a shared expiry must not make one key")
    }

    func testUseRequestNamesTheExactRecordAndWindow() async throws {
        let http = RoutingHTTPClient { _ in Self.response(#"{"success":true}"#) }
        _ = try await ZAIUsageClient(http: http).useReset(Self.weekly21, requestID: "request-1", apiKey: "key-1")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, ZAIUsageClient.useResetURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer key-1")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? NSDictionary)
        XCTAssertEqual(body, ["targetType": "PERSONAL", "resetType": "WEEK", "recordId": 21, "requestId": "request-1"])
    }

    func testOnlySuccessTrueCountsAsSpent() {
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: Self.response(#"{"success":true}"#)), .success)
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: Self.response(#"{"success":false,"msg":"no"}"#)), .failed(.refused))
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: Self.response(#"{"success":true}"#, status: 500)), .failed(.refused))
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: Self.response("{}", status: 401)), .failed(.signInExpired))
    }

    func testRefreshAddsTheResetsRowAndTheClaimServiceListsThem() async throws {
        let runtime = try makeRuntime(RoutingHTTPClient { Self.route($0) })
        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.lines.last, ZAIResetsMapper.line([Self.session11, Self.weekly21, Self.session12]))
        let service = try XCTUnwrap(runtime.resetClaimService { .refreshed })
        XCTAssertEqual(service.windowResets, [Self.session11, Self.weekly21, Self.session12])
        XCTAssertFalse(service.isClaimable, "the flat timeline stays read-only")
        XCTAssertEqual(runtime.widgetDescriptors.map(\.key), ["session", "weekly", "webSearches", "rateLimitResets"])
    }

    func testAFailedResetListLeavesTheMetersWorking() async throws {
        for failure in [Self.response("{}", status: 500), Self.response("not json")] {
            let runtime = try makeRuntime(RoutingHTTPClient { request in
                request.url == ZAIUsageClient.resetListURL ? failure : Self.route(request)
            })
            let snapshot = try await runtime.refresh().get()
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        }
    }

    func testClaimSpendsTheConfirmedRecordOnceAndRereadsTheList() async throws {
        let http = RoutingHTTPClient { Self.route($0) }
        let runtime = try makeRuntime(http)
        _ = await runtime.refresh()
        let refreshed = expectation(description: "the post-claim refresh")
        let service = try XCTUnwrap(runtime.resetClaimService {
            defer { refreshed.fulfill() }
            _ = await runtime.refresh()
            return .refreshed
        })
        let sentBefore = http.requests.count

        let outcome = await service.claim(Self.weekly21, requestID: "request-1")
        await fulfillment(of: [refreshed], timeout: 5)

        XCTAssertEqual(outcome, .success)
        let sent = http.requests.dropFirst(sentBefore).map(\.url)
        XCTAssertEqual(sent.filter { $0 == ZAIUsageClient.useResetURL }.count, 1)
        XCTAssertEqual(sent.filter { $0 == ZAIUsageClient.resetListURL }.count, 2, "checked before the claim, read again after it")
    }

    func testAStaleRecordIsNeverSpentInPlaceOfAnother() async throws {
        let runtime = try makeRuntime(RoutingHTTPClient { Self.route($0) })
        _ = await runtime.refresh()
        let stale = [
            ZAIReset(window: .fiveHour, recordID: 99, expiresAt: Self.session11.expiresAt),
            Self.session12,
            ZAIReset(window: .fiveHour, recordID: 11, expiresAt: Self.session11.expiresAt.addingTimeInterval(60))
        ]
        for confirmed in stale {
            let http = RoutingHTTPClient { Self.route($0) }
            let claimRuntime = try makeRuntime(http)
            let outcome = await claimRuntime.claimZAIReset(confirmed, requestID: "request-1")
            XCTAssertEqual(outcome, .noCredit, "\(confirmed)")
            XCTAssertFalse(http.requests.contains { $0.url == ZAIUsageClient.useResetURL }, "\(confirmed)")
        }
    }

    func testALostAnswerIsNotRetried() async throws {
        let http = RoutingHTTPClient { request in
            if request.url == ZAIUsageClient.useResetURL { throw URLError(.timedOut) }
            return Self.route(request)
        }
        let outcome = await (try makeRuntime(http)).claimZAIReset(Self.session11, requestID: "request-1")
        XCTAssertEqual(outcome, .failed(.connection))
        XCTAssertEqual(http.requests.filter { $0.url == ZAIUsageClient.useResetURL }.count, 1)
    }

    private func makeRuntime(_ http: RoutingHTTPClient) throws -> AccountProviderRuntime {
        let account = Account(kind: .zai, label: "Personal")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        return AccountProviderRuntime(account: account, vault: vault, http: http, now: { Self.now })
    }

    private nonisolated static func route(_ request: HTTPRequest) -> HTTPResponse {
        switch request.url {
        case ZAIUsageClient.quotaURL: response(quota)
        case ZAIUsageClient.resetListURL: response(list)
        case ZAIUsageClient.useResetURL: response(#"{"code":200,"success":true}"#)
        default: response("{}", status: 404)
        }
    }

    private nonisolated static func response(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }
}
