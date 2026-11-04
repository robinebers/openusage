import XCTest
@testable import OpenUsage

final class CodexUsageClientAndMapperTests: XCTestCase {
    func testRefreshEncodesReservedCharactersInRequestBody() async throws {
        let http = RoutingHTTPClient { _ in .json(#"{"access_token":"new-token"}"#) }

        _ = try await CodexLogin.refresh("refresh token&=+/?%", http: http, now: Date())

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, CodexLogin.tokenURL)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=\(CodexLogin.clientID)" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshRejectsAnExpiredSession() async {
        let http = RoutingHTTPClient { _ in .json(#"{"error":{"code":"refresh_token_expired"}}"#, status: 400) }

        do {
            _ = try await CodexLogin.refresh("refresh", http: http, now: Date())
            XCTFail("expected refreshToken to throw")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .signInExpired(.codex))
        } catch {
            XCTFail("expected ProviderError.signInExpired(.codex), got \(error)")
        }
    }

    @MainActor
    func testExtraUsageCreditsHideWhileCreditsAreOffAndShowAtZeroWhileOn() throws {
        let account = Account(kind: .codex, label: "ChatGPT")
        let provider = AccountProviderRuntime.provider(for: account)
        let descriptor = try XCTUnwrap(AccountProviderRuntime.widgetDescriptors(for: account).first { $0.key == "credits" })
        let cases: [(String, Double?)] = [(#"{ "has_credits": false, "balance": "0" }"#, nil), (#"{ "has_credits": false }"#, nil),
                                          (#"{ "has_credits": true, "balance": "0" }"#, 0), (#"{ "balance": 0 }"#, 0),
                                          (#"{ "has_credits": true, "balance": "1" }"#, 1)]
        for (credits, balance) in cases {
            let body = Data(#"{ "credits": \#(credits) }"#.utf8)
            let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
            let usage = try CodexUsageMapper.mapUsageResponse(response)
            let snapshot = ProviderSnapshot(provider: provider, plan: usage.plan, lines: usage.lines)
            let defaults = isolatedDefaults()
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
            cache.save([provider.id: snapshot])
            let runtime = StubRuntime(provider: provider, descriptors: [descriptor], snapshot: snapshot)
            let store = WidgetDataStore.forTesting([runtime], cache: cache, defaults: defaults)
            let accounts = store.accounts(in: [ProviderMetrics(provider: provider, metrics: [descriptor])])

            XCTAssertEqual(descriptor.balance(in: store.data(for: descriptor))?.number, balance, credits)
            XCTAssertEqual(accounts.first?.lines.map(\.descriptor.key), balance == nil ? [] : ["credits"], credits)
        }
    }

    func testInvalidDedicatedResponsesFallBackToUsageBodyCount() throws {
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 3 } }"#.utf8))
        let cases: [(name: String, response: HTTPResponse?)] = [
            ("missing", nil),
            ("null count", HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"available_count":null}"#.utf8))),
            ("server failure", HTTPResponse(statusCode: 500, headers: [:], body: Data("<html>oops</html>".utf8)))
        ]

        for entry in cases {
            let mapped = try CodexUsageMapper.mapUsageResponse(
                usage, resetCredits: entry.response, now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            guard case .values(_, let values, let expiriesAt) = mapped.lines.first else {
                return XCTFail("expected reset credits when dedicated response is \(entry.name)")
            }
            XCTAssertEqual(values, [MetricValue(number: 3, kind: .count, label: "available")], entry.name)
            XCTAssertTrue(expiriesAt.isEmpty, entry.name)
        }
    }

    func testOmitsRateLimitResetsWhenCountMalformed() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": null } }"#.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body), now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(mapped.lines.first { $0.label == "Rate Limit Resets" })
    }

    func testDropsWindowLengthCountAndCreditsTooLargeForAnInt() throws {
        let body = Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":1e300}},
         "rate_limit_reset_credits":{"available_count":1e300},"credits":{"balance":1e300}}
        """#.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(HTTPResponse(statusCode: 200, headers: [:], body: body))

        XCTAssertEqual(mapped.lines.map(\.label), ["Session"])
        guard case .progress(_, _, _, _, _, let periodMs) = mapped.lines.first else { return XCTFail("expected Session meter") }
        XCTAssertEqual(periodMs, MetricPeriod.sessionMs)
    }
}
