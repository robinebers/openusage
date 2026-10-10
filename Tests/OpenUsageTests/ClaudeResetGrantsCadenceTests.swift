import XCTest
@testable import OpenUsage

/// Issue #1355: the reset-grants request is the one Anthropic throttles when polled, so the regular
/// refresh reads plain usage and the Rate Limit Resets row is checked at most once an hour per login.
@MainActor
final class ClaudeResetGrantsCadenceTests: XCTestCase {
    private static let start = OpenUsageISO8601.date(from: "2026-10-09T12:00:00.000Z")!
    private static let credentials =
        #"{"claudeAiOauth":{"accessToken":"token-a","refreshToken":"refresh-a","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

    func testRegularRefreshReadsPlainUsageAndChecksResetGrantsHourly() async {
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.url.query == nil ? Self.usage() : Self.grants(resetsLeft: 1)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http, clock: clock)

        let first = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(5 * 60))
        let second = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(61 * 60))
        _ = await provider.refresh()

        XCTAssertEqual(usageQueries(http), [nil, "cedar_ember=1&skip_spend=1", nil, nil, "cedar_ember=1&skip_spend=1"])
        XCTAssertEqual(resetsAvailable(first.lines), 1)
        XCTAssertEqual(resetsAvailable(second.lines), 1)
    }

    func testFailedResetGrantsCheckKeepsBarsAndWaitsAnHour() async {
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.url.query == nil
                    ? Self.usage()
                    : HTTPResponse(statusCode: 429, headers: ["retry-after": "3000"], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http, clock: clock)

        let first = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(5 * 60))
        let second = await provider.refresh()

        XCTAssertNil(first.warning)
        XCTAssertNotNil(first.lines.first { $0.label == "Session" })
        XCTAssertNil(resetsAvailable(first.lines))
        XCTAssertNotNil(second.lines.first { $0.label == "Session" })
        XCTAssertEqual(usageQueries(http), [nil, "cedar_ember=1&skip_spend=1", nil])
    }

    func testHeldResetGrantDropsOnceItsDeadlinePasses() async {
        let clock = TestClock(Self.start)
        let deadline = Self.start.addingTimeInterval(10 * 60)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.url.query == nil ? Self.usage() : Self.grants(resetsLeft: 1, endsAt: deadline)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http, clock: clock)

        let first = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(15 * 60))
        let second = await provider.refresh()

        XCTAssertEqual(resetsAvailable(first.lines), 1)
        XCTAssertEqual(resetsAvailable(second.lines), 0)
    }

    func testTokenRotationKeepsLastGoodGrantsWhenHourlyCheckFails() async {
        let clock = TestClock(Self.start)
        let expiresAt = Int(Self.start.addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000)
        let files = FakeFiles(["/tmp/claude/.credentials.json": Self.credentials
            .replacingOccurrences(of: "4102444800000", with: String(expiresAt))])
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/v1/oauth/token":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"token-b","refresh_token":"refresh-b","expires_in":7200}"#.utf8))
            case "/api/oauth/usage":
                if request.url.query == nil { return Self.usage() }
                return request.headers["Authorization"] == "Bearer token-a"
                    ? Self.grants(resetsLeft: 1)
                    : HTTPResponse(statusCode: 429, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http, clock: clock, files: files)

        let first = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(61 * 60))
        let rotated = await provider.refresh()
        clock.set(Self.start.addingTimeInterval(62 * 60))
        let held = await provider.refresh()

        XCTAssertEqual(resetsAvailable(first.lines), 1)
        XCTAssertEqual(resetsAvailable(rotated.lines), 1)
        XCTAssertEqual(resetsAvailable(held.lines), 1)
        XCTAssertEqual(http.requests.filter { $0.isClaudeResetGrantsCheck }.count, 2)
    }

    func testLoginReplacementDuringGrantsReloadsUsageAndDoesNotCacheOldGrants() async {
        for statusCode in [200, 429] {
            let clock = TestClock(Self.start)
            let files = FakeFiles(["/tmp/claude/.credentials.json": Self.credentials])
            let replacement = Self.credentials.replacingOccurrences(of: "token-a", with: "token-b")
                .replacingOccurrences(of: "refresh-a", with: "refresh-b")
            let http = RoutingHTTPClient { request in
                guard request.url.path == "/api/oauth/usage" else {
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
                let originalLogin = request.headers["Authorization"] == "Bearer token-a"
                if request.url.query == nil { return Self.usage(used: originalLogin ? 42 : 77) }
                if originalLogin {
                    files.files["/tmp/claude/.credentials.json"] = replacement
                    return statusCode == 200 ? Self.grants(resetsLeft: 1)
                        : HTTPResponse(statusCode: statusCode, headers: [:], body: Data())
                }
                return Self.grants(resetsLeft: 2)
            }
            let provider = makeProvider(http: http, clock: clock, files: files)

            let replaced = await provider.refresh()
            let held = await provider.refresh()

            XCTAssertNil(replaced.warning)
            guard case .progress(_, let used, _, _, _, _, _) = replaced.line(label: "Session") else {
                return XCTFail("Expected replacement login's live usage")
            }
            XCTAssertEqual(used, 77)
            XCTAssertEqual(resetsAvailable(replaced.lines), 2)
            XCTAssertEqual(resetsAvailable(held.lines), 2)
            XCTAssertEqual(http.requests.filter { $0.isClaudeResetGrantsCheck }.count, 2)
        }
    }

    func testLoginReplacementDuringProfileReloadsUsageBeforePublishing() async {
        let clock = TestClock(Self.start)
        let files = FakeFiles(["/tmp/claude/.credentials.json": Self.credentials])
        let replacement = Self.credentials.replacingOccurrences(of: "token-a", with: "token-b")
            .replacingOccurrences(of: "refresh-a", with: "refresh-b")
        let http = RoutingHTTPClient { request in
            let originalLogin = request.headers["Authorization"] == "Bearer token-a"
            switch request.url.path {
            case "/api/oauth/usage":
                return request.url.query == nil ? Self.usage(used: originalLogin ? 42 : 77)
                    : Self.grants(resetsLeft: originalLogin ? 1 : 2)
            case "/api/oauth/profile":
                if originalLogin { files.files["/tmp/claude/.credentials.json"] = replacement }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http, clock: clock, files: files)

        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Expected replacement login's live usage")
        }
        XCTAssertEqual(used, 77)
        XCTAssertEqual(resetsAvailable(snapshot.lines), 2)
    }

    // MARK: - Helpers

    private func makeProvider(http: RoutingHTTPClient, clock: TestClock, files: FakeFiles? = nil) -> ClaudeProvider {
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files ?? FakeFiles(["/tmp/claude/.credentials.json": Self.credentials]),
            keychain: FakeKeychain(),
            now: { clock.now }
        )
        return ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )
    }

    private func usageQueries(_ http: RoutingHTTPClient) -> [String?] {
        http.requests.filter { $0.url.path == "/api/oauth/usage" }.map(\.url.query)
    }

    private func resetsAvailable(_ lines: [MetricLine]) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return nil
        }
        return values.first?.number
    }

    private nonisolated static func usage(used: Int = 42) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(used),"resets_at":"2099-01-01T00:00:00.000Z"},"cedar_ember":null}"#.utf8)
        )
    }

    private nonisolated static func grants(resetsLeft: Int, endsAt: Date? = nil) -> HTTPResponse {
        let endsAtJSON = endsAt.map { "\"\(OpenUsageISO8601.string(from: $0))\"" } ?? "null"
        return HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":\#(resetsLeft),"ends_at":\#(endsAtJSON)}]}}"#.utf8)
        )
    }
}
