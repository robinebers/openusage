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
        {"recordId":12,"available":true,"expireTime":"2026-11-10 08:00:00","grantType":"GLOBAL"},
        {"recordId":11,"available":true,"expireTime":"2026-11-06 20:00:00","grantType":"GLOBAL"},
        {"recordId":13,"available":false,"expireTime":"2026-11-07 08:00:00","grantType":"GLOBAL"},
        {"recordId":14,"available":true,"expireTime":"2026-11-03 08:00:00","grantType":"GLOBAL"}
      ],
      "weekResets":[{"recordId":21,"available":true,"expireTime":"2026-11-06 20:00:00","grantType":"GLOBAL"}]
    }}
    """#

    private nonisolated static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private nonisolated static let session11 = ZAIReset(window: .fiveHour, recordID: 11, expiresAt: utc("2026-11-06T12:00:00Z"), grantType: "GLOBAL")
    private nonisolated static let weekly21 = ZAIReset(window: .week, recordID: 21, expiresAt: utc("2026-11-06T12:00:00Z"), grantType: "GLOBAL")
    private nonisolated static let session12 = ZAIReset(window: .fiveHour, recordID: 12, expiresAt: utc("2026-11-10T00:00:00Z"), grantType: "GLOBAL")

    func testListKeepsAvailableUnexpiredResetsOfBothWindowsEarliestFirstInUTCPlus8() throws {
        let resets = try ZAIResetsMapper.resets(from: Data(Self.list.utf8), now: Self.now)
        XCTAssertEqual(resets, [Self.session11, Self.weekly21, Self.session12])
    }

    func testListRejectsAnUnreadableRecordOrAFailedAnswer() {
        for body in [
            #"{"success":true,"data":{"fiveHourResets":[{"recordId":1,"available":true,"expireTime":"2026-11-06T20:00:00Z"}]}}"#,
            #"{"success":true,"data":{"weekResets":[{"available":true,"expireTime":"2026-11-06 20:00:00"}]}}"#,
            #"{"success":true,"data":{"weekResets":[{"recordId":1,"available":true,"expireTime":"2026-11-06 20:00:00"}]}}"#,
            #"{"success":true,"data":{"weekResets":[{"recordId":1,"available":true,"expireTime":"2026-11-06 20:00:00","grantType":""}]}}"#,
            #"{"success":false,"msg":"error","data":null}"#
        ] {
            XCTAssertThrowsError(try ZAIResetsMapper.resets(from: Data(body.utf8), now: Self.now), body)
        }
    }

    func testDetailListsEachWindowApartAndKeysEqualExpiriesApart() {
        let windows = RateLimitResetsDetail.windows([Self.session11, Self.weekly21, Self.session12], now: Self.now)
        XCTAssertEqual(windows.map(\.window), [.fiveHour, .week])
        XCTAssertEqual(windows.map { $0.entries.compactMap(\.key.reset?.recordID) }, [[11, 12], [21]])
        XCTAssertNotEqual(windows[0].entries[0].key, windows[1].entries[0].key, "a shared expiry must not make one key")
        let replacement = ZAIReset(window: .fiveHour, recordID: 99, expiresAt: Self.session11.expiresAt, grantType: "GLOBAL")
        let replaced = RateLimitResetsDetail.windows([replacement, Self.weekly21, Self.session12], now: Self.now)
        XCTAssertNotEqual(replaced[0].entries[0].key, windows[0].entries[0].key, "a confirm never carries over to another record")
        let unsorted = RateLimitResetsDetail.windows([Self.session12, Self.session11], now: Self.now)[0].entries
        XCTAssertEqual(unsorted.map(\.date), unsorted.compactMap(\.key.reset?.expiresAt), "each date keeps its own record")
        XCTAssertEqual(unsorted.first?.key.reset, Self.session11)
    }

    func testUseRequestNamesTheExactRecordAndWindow() async throws {
        let http = RoutingHTTPClient { _ in .json(#"{"success":true}"#) }
        _ = try await ZAIUsageClient(http: http).useReset(Self.weekly21, requestID: "request-1", apiKey: "key-1")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, ZAIUsageClient.useResetURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer key-1")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? NSDictionary)
        XCTAssertEqual(body, ["targetType": "PERSONAL", "resetType": "WEEK", "recordId": 21, "requestId": "request-1", "grantType": "GLOBAL"])
    }

    func testOnlySuccessTrueCountsAsSpent() {
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: .json(#"{"success":true}"#)), .success)
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: .json(#"{"success":false,"msg":"no"}"#)), .failed(.refused))
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: .json(#"{"success":true}"#, status: 500)), .failed(.refused))
        XCTAssertEqual(ZAIResetsMapper.claimOutcome(from: .json("{}", status: 401)), .failed(.signInExpired))
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
        for failure in [HTTPResponse.json("{}", status: 500), .json("not json")] {
            let runtime = try makeRuntime(RoutingHTTPClient { request in
                request.url == ZAIUsageClient.resetListURL ? failure : Self.route(request)
            })
            let snapshot = try await runtime.refresh().get()
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        }
    }

    func testClaimSpendsTheConfirmedRecordOnceAndTheRowDropsIt() async throws {
        let expiry = Self.zaiTime(Date().addingTimeInterval(2 * 86_400))
        let claimed = TestSwitch(false)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case ZAIUsageClient.resetListURL:
                let record = #"{"recordId":7,"available":\#(!claimed.value),"expireTime":"\#(expiry)","grantType":"GLOBAL"}"#
                return .json(#"{"success":true,"data":{"weekResets":[\#(record)]}}"#)
            case ZAIUsageClient.useResetURL:
                claimed.value = true
                return .json(#"{"success":true}"#)
            default:
                return Self.route(request)
            }
        }
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let account = accounts.add(kind: .zai, label: "Personal", credential: .apiKey("key"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let row = try XCTUnwrap(AccountProviderRuntime.widgetDescriptors(for: account).last)
        await container.dataStore.refresh(providerID: account.cardID)
        XCTAssertEqual(container.dataStore.data(for: row).unboundedDetail, "1 available")
        let service = try XCTUnwrap(container.resetClaim(for: account.cardID))

        let outcome = await service.claim(try XCTUnwrap(service.windowResets.first), requestID: "request-1")

        XCTAssertEqual(outcome, .success)
        for _ in 0..<500 where container.dataStore.data(for: row).unboundedDetail != "0 available" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(container.dataStore.data(for: row).unboundedDetail, "0 available", "the post-claim refresh rereads the list")
        XCTAssertEqual(http.requests.filter { $0.url == ZAIUsageClient.useResetURL }.count, 1)
    }

    private nonisolated static func zaiTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func testAStaleRecordIsNeverSpentInPlaceOfAnother() async throws {
        let stale = [
            ZAIReset(window: .fiveHour, recordID: 99, expiresAt: Self.session11.expiresAt, grantType: "GLOBAL"),
            Self.session12,
            ZAIReset(window: .fiveHour, recordID: 11, expiresAt: Self.session11.expiresAt.addingTimeInterval(60), grantType: "GLOBAL")
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
        case ZAIUsageClient.quotaURL: .json(quota)
        case ZAIUsageClient.resetListURL: .json(list)
        case ZAIUsageClient.useResetURL: .json(#"{"code":200,"success":true}"#)
        default: .json("{}", status: 404)
        }
    }
}
