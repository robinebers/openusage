import XCTest
@testable import OpenUsage

final class CodexUsageClientAndMapperTests: XCTestCase {
    func testRefreshEncodesReservedCharactersInRequestBody() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"access_token":"new-token"}"#.utf8)
        ))

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
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 400,
            headers: [:],
            body: Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        ))

        do {
            _ = try await CodexLogin.refresh("refresh", http: http, now: Date())
            XCTFail("expected refreshToken to throw")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .signInExpired(.codex))
        } catch {
            XCTFail("expected ProviderError.signInExpired(.codex), got \(error)")
        }
    }

    func testUsageMapperKeepsProviderReportedSessionLimit() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"rate_limit":{"primary_window":{"used_percent":42,"reset_after_seconds":3600}}}"#.utf8)
        )
        let mapped = try CodexUsageMapper.mapUsageResponse(response)

        guard case .progress(_, let used, let limit, _, _, _) = mapped.lines.first(where: { $0.label == "Session" })
        else { return XCTFail("expected Session meter") }
        XCTAssertEqual(used, 42)
        XCTAssertEqual(limit, 100)
    }

    func testCreditsRowLeadsWithTheirDollarValueAtFourCentsACredit() throws {
        let cases = [
            (credits: #"{ "balance": 821.6 }"#, row: "$32.84 · 821 credits"),
            (credits: #"{ "has_credits": false }"#, row: "$0 · 0 credits")
        ]
        for (credits, row) in cases {
            let body = Data(#"{ "credits": \#(credits) }"#.utf8)
            let mapped = try CodexUsageMapper.mapUsageResponse(HTTPResponse(statusCode: 200, headers: [:], body: body))
            guard case .values(_, let values, _) = mapped.lines.first(where: { $0.label == "Credits" })
            else { return XCTFail("expected a Credits row for \(credits)") }
            var data = WidgetData(title: "Extra Usage", kind: .dollars, used: 0, limit: nil)
            data.values = values
            XCTAssertEqual(data.unboundedDetail, row)
        }
    }

    func testShowsRateLimitResetsBeforeCredits() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": 1 }, "credits": { "balance": 100 } }"#.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body), now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(resetsValues(mapped.lines), [MetricValue(number: 1, kind: .count, label: "available")])
        XCTAssertEqual(mapped.lines.map(\.label), ["Rate Limit Resets", "Credits"])
    }

    func testShowsZeroRateLimitResets() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": 0 } }"#.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body), now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(resetsValues(mapped.lines), [MetricValue(number: 0, kind: .count, label: "available")])
    }

    func testDedicatedEndpointSortsAvailableExpiriesWithExplicitOrMissingStatus() throws {
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let expectedExpiries = [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ]

        for status in ["available", nil] as [String?] {
            let statusField = status.map { "\"status\":\"\($0)\"," } ?? ""
            let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"available_count":2,"credits":[
              {\(statusField)"expires_at":"2026-02-20T19:00:00.000Z"},
              {\(statusField)"expires_at":"2026-02-20T17:30:00.000Z"},
              {"status":"consumed","expires_at":"2026-02-20T16:10:00.000Z"}
            ]}
            """.utf8))
            let mapped = try CodexUsageMapper.mapUsageResponse(
                usage, resetCredits: resetCredits, now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
            )

            guard case .values(_, let values, let expiriesAt) = mapped.lines.first else {
                return XCTFail("expected reset credits for status \(status ?? "omitted")")
            }
            XCTAssertEqual(values, [MetricValue(number: 2, kind: .count, label: "available")])
            XCTAssertEqual(expiriesAt, expectedExpiries, status ?? "omitted")
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

        XCTAssertNil(resetsValues(mapped.lines))
    }

    private func resetsValues(_ lines: [MetricLine]) -> [MetricValue]? {
        guard case .values(_, let values, _) = lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return nil
        }
        return values
    }
}
