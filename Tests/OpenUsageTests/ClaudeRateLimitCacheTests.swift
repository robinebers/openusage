import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeRateLimitCacheTests: XCTestCase {
    private let credentialsPath = "/tmp/claude/.credentials.json"
    private let fixedNow = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!

    func testRateLimitedResponseMapsToRetryBadgeNotError() async {
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
        ) { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        XCTAssertEqual(
            snapshot.warning,
            "Updates blocked by Anthropic. Live requests are paused while OpenUsage backs off. Retrying in ~10m."
        )
    }

    func testRateLimitServesLastGoodUsageThenBacksOff() async {
        let clock = CacheTestClock(fixedNow)
        let usageCalls = CacheCallCounter()
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#,
            now: { clock.now }
        ) { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return Self.usageResponse(percent: 25)
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let first = await fixture.provider.refresh()
        XCTAssertEqual(progress(first.lines, "Session")?.used, 25)
        XCTAssertNil(first.warning)

        let second = await fixture.provider.refresh()
        XCTAssertEqual(progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(second.warning?.hasPrefix("Updates blocked by Anthropic"), true)

        clock.set(fixedNow.addingTimeInterval(60))
        let third = await fixture.provider.refresh()
        XCTAssertEqual(progress(third.lines, "Session")?.used, 25)
        XCTAssertEqual(third.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(usageRequests(fixture.http).count, 2)
    }

    func testRateLimitKeepsLastGoodUsageAfterProactiveTokenRotation() async {
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return Self.refreshResponse(accessToken: "new-token", refreshToken: "refresh-2")
            }
            if request.headers["Authorization"] == "Bearer old-token" {
                return Self.usageResponse(percent: 25)
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let first = await fixture.provider.refresh()
        XCTAssertEqual(progress(first.lines, "Session")?.used, 25)

        fixture.files.files[credentialsPath] =
            #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"refresh-1","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let second = await fixture.provider.refresh()

        XCTAssertEqual(progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(usageAuthorizations(fixture.http), ["Bearer old-token", "Bearer new-token"])
    }

    func testSwappedRefreshTokenCannotMigrateAnotherAccountsCachedUsage() async {
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"shared-access","refreshToken":"account-a-refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                XCTAssertEqual(
                    String(data: request.body ?? Data(), encoding: .utf8)?.contains("account-b-refresh"),
                    true
                )
                return Self.refreshResponse(
                    accessToken: "account-b-access",
                    refreshToken: "account-b-refresh-2"
                )
            }
            if request.headers["Authorization"] == "Bearer shared-access" {
                return Self.usageResponse(percent: 25)
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let accountA = await fixture.provider.refresh()
        XCTAssertEqual(progress(accountA.lines, "Session")?.used, 25)

        fixture.files.files[credentialsPath] =
            #"{"claudeAiOauth":{"accessToken":"shared-access","refreshToken":"account-b-refresh","expiresAt":1,"subscriptionType":"max","scopes":["user:profile"]}}"#
        let accountB = await fixture.provider.refresh()

        XCTAssertEqual(accountB.plan, "Max")
        XCTAssertNil(progress(accountB.lines, "Session"), "account A usage must not cross into account B")
        XCTAssertEqual(badge(accountB.lines, "Status")?.hasPrefix("Rate limited"), true)
    }

    func testRateLimitKeepsLastGoodUsageAfter401TokenRotation() async {
        let oldTokenCalls = CacheCallCounter()
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return Self.refreshResponse(accessToken: "new-token", refreshToken: "refresh-2")
            }
            if request.headers["Authorization"] == "Bearer old-token" {
                return oldTokenCalls.next() == 1
                    ? Self.usageResponse(percent: 25)
                    : HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let first = await fixture.provider.refresh()
        XCTAssertEqual(progress(first.lines, "Session")?.used, 25)

        let second = await fixture.provider.refresh()

        XCTAssertEqual(progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(
            usageAuthorizations(fixture.http),
            ["Bearer old-token", "Bearer old-token", "Bearer new-token"]
        )
    }

    func testRateLimitNeverReusesLastGoodUsageAfterLoginChanges() async {
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"account-a","subscriptionType":"pro","scopes":["user:profile"]}}"#
        ) { request in
            if request.headers["Authorization"] == "Bearer account-a" {
                return Self.usageResponse(percent: 25)
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let first = await fixture.provider.refresh()
        XCTAssertEqual(progress(first.lines, "Session")?.used, 25)

        fixture.files.files[credentialsPath] =
            #"{"claudeAiOauth":{"accessToken":"account-b","subscriptionType":"max","scopes":["user:profile"]}}"#
        let second = await fixture.provider.refresh()

        XCTAssertEqual(second.plan, "Max")
        XCTAssertNil(progress(second.lines, "Session"), "account A usage must not cross into account B")
        XCTAssertEqual(badge(second.lines, "Status")?.hasPrefix("Rate limited"), true)
    }

    func testOldLoginCooldownDoesNotSuppressNewLoginFetch() async {
        let clock = CacheTestClock(fixedNow)
        let accountACalls = CacheCallCounter()
        let fixture = makeFixture(
            credentials: #"{"claudeAiOauth":{"accessToken":"account-a","subscriptionType":"pro","scopes":["user:profile"]}}"#,
            now: { clock.now }
        ) { request in
            if request.headers["Authorization"] == "Bearer account-a" {
                return accountACalls.next() == 1
                    ? Self.usageResponse(percent: 25)
                    : HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
            }
            return Self.usageResponse(percent: 70)
        }

        _ = await fixture.provider.refresh()
        _ = await fixture.provider.refresh()
        fixture.files.files[credentialsPath] =
            #"{"claudeAiOauth":{"accessToken":"account-b","subscriptionType":"max","scopes":["user:profile"]}}"#

        let switched = await fixture.provider.refresh()

        XCTAssertEqual(progress(switched.lines, "Session")?.used, 70)
        XCTAssertEqual(usageRequests(fixture.http).count, 3, "account B must bypass account A's cooldown")
    }

    private struct Fixture {
        let provider: ClaudeProvider
        let files: FakeFiles
        let http: RoutingHTTPClient
    }

    private func makeFixture(
        credentials: String,
        now: @escaping @Sendable () -> Date = {
            OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        },
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        let files = FakeFiles([credentialsPath: credentials])
        let http = RoutingHTTPClient(handler: handler)
        return Fixture(
            provider: ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                    files: files,
                    keychain: FakeKeychain(),
                    now: now
                ),
                usageClient: ClaudeUsageClient(httpClient: http),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                now: now,
                pricing: { TestPricing.bundled }
            ),
            files: files,
            http: http
        )
    }

    private nonisolated static func usageResponse(percent: Double) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }

    private nonisolated static func refreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(
                #"{"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)","expires_in":3600}"#.utf8
            )
        )
    }

    private func usageRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
    }

    private func usageAuthorizations(_ http: RoutingHTTPClient) -> [String] {
        usageRequests(http).compactMap { $0.headers["Authorization"] }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let value, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return value
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return value
    }
}

private final class CacheCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class CacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
