import XCTest
@testable import OpenUsage

/// Issue #1258: the plan badge must follow Anthropic's live profile, not the tier Claude Code stamped into
/// the login at sign-in — while never becoming a second poll against the rate-limited usage API.
@MainActor
final class ClaudeLivePlanTests: XCTestCase {
    private static let staleMax5x =
        #"{"claudeAiOauth":{"accessToken":"token-a","refreshToken":"refresh-a","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:profile"]}}"#

    func testFormatLivePlanReadsOrganizationTierAndFallsBackToStoredFields() {
        let stored = ClaudeOAuth(subscriptionType: "max", rateLimitTier: "default_claude_max_5x")

        XCTAssertEqual(
            ClaudeUsageMapper.formatLivePlan(
                profile: profile(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"),
                credentials: stored
            ),
            "Max 20x"
        )
        XCTAssertEqual(
            ClaudeUsageMapper.formatLivePlan(profile: profile(organizationType: "claude_pro", rateLimitTier: nil), credentials: stored),
            "Pro 5x"
        )
        XCTAssertEqual(
            ClaudeUsageMapper.formatLivePlan(profile: profile(organizationType: nil, rateLimitTier: "default_claude_max_20x"), credentials: stored),
            "Max 20x"
        )
        XCTAssertNil(ClaudeUsageMapper.formatLivePlan(
            profile: ClaudeAccountProfile(account: .init(uuid: "a"), organization: nil),
            credentials: stored
        ))
    }

    func testPlanBadgeFollowsLiveProfileAndFetchesItOncePerToken() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage": return Self.usage(percent: 42)
            case "/api/oauth/profile": return Self.profileResponse(tier: "default_claude_max_20x")
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(credentials: Self.staleMax5x, http: http)

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 20x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(progress(first.lines, "Session")?.used, 42)
        // Profile only after the usage call proved the token, and never again for the same token.
        XCTAssertEqual(http.requests.map(\.url.path), [
            "/api/oauth/usage", "/api/oauth/profile", "/api/oauth/usage"
        ])
    }

    func testProfileFailureKeepsStoredPlanAndBarsWithoutRetryingOnSameToken() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage": return Self.usage(percent: 42)
            case "/api/oauth/profile": return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(credentials: Self.staleMax5x, http: http)

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 5x")
        XCTAssertEqual(second.plan, "Max 5x")
        XCTAssertEqual(progress(first.lines, "Session")?.used, 42)
        XCTAssertEqual(progress(second.lines, "Session")?.used, 42)
        XCTAssertNil(first.warning)
        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 1)
    }

    func testTokenRotationTriggersOneFreshProfileLookup() async {
        let usageCalls = CallCounter()
        let http = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            switch request.url.path {
            case "/api/oauth/usage":
                // Second refresh: token-a has been revoked upstream, forcing a rotation to token-b.
                if usageCalls.next() == 2, authorization == "Bearer token-a" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return Self.usage(percent: 42)
            case "/v1/oauth/token":
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"access_token":"token-b","refresh_token":"refresh-b","expires_in":3600}"#.utf8)
                )
            case "/api/oauth/profile":
                let tier = authorization == "Bearer token-b" ? "default_claude_max_20x" : "default_claude_max_5x"
                return Self.profileResponse(tier: tier)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(credentials: Self.staleMax5x, http: http)

        let first = await provider.refresh()
        let second = await provider.refresh()
        let third = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 5x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(third.plan, "Max 20x")
        XCTAssertEqual(
            http.requests.filter { $0.url.path == "/api/oauth/profile" }.map { $0.headers["Authorization"] },
            ["Bearer token-a", "Bearer token-b"]
        )
    }

    func testIdentityBoundCardReusesVerificationProfileWithNoExtraRequest() async {
        let account = "11111111-1111-4111-8111-111111111111"
        let organization = "22222222-2222-4222-8222-222222222222"
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return Self.usage(percent: 42)
            case "/api/oauth/profile":
                return Self.profileResponse(tier: "default_claude_max_20x", account: account, organization: organization)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(
            credentials: Self.staleMax5x, http: http, expectedIdentityKey: "\(account)|\(organization)"
        )

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 20x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(http.requests.map(\.url.path), [
            "/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage"
        ])
    }

    func testIdentityBoundCardShowsLivePlanOnRateLimitedBadgeBeforeAnyUsageSucceeds() async {
        // Verification succeeded (so the live profile is in hand) but the very first usage call 429s:
        // the rate-limited badge must already carry the live plan, not the stale stored one.
        let account = "11111111-1111-4111-8111-111111111111"
        let organization = "22222222-2222-4222-8222-222222222222"
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
            case "/api/oauth/profile":
                return Self.profileResponse(tier: "default_claude_max_20x", account: account, organization: organization)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(
            credentials: Self.staleMax5x, http: http, expectedIdentityKey: "\(account)|\(organization)"
        )

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 20x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(first.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
    }

    func testInferenceOnlyLoginNeverLooksUpProfile() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("An inference-only login must not call any Anthropic endpoint")
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeProvider(
            credentials: #"{"claudeAiOauth":{"accessToken":"token-a","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}"#,
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max 5x")
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: - Helpers

    private func makeProvider(
        credentials: String,
        http: RoutingHTTPClient,
        expectedIdentityKey: String? = nil
    ) -> ClaudeProvider {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: FakeFiles(["/tmp/claude/.credentials.json": credentials]),
            keychain: FakeKeychain(),
            expectedIdentityKey: expectedIdentityKey,
            now: { now }
        )
        return ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    private func profile(organizationType: String?, rateLimitTier: String?) -> ClaudeAccountProfile {
        ClaudeAccountProfile(
            account: .init(uuid: "account"),
            organization: .init(uuid: "organization", organizationType: organizationType, rateLimitTier: rateLimitTier)
        )
    }

    private nonisolated static func usage(percent: Int) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }

    private nonisolated static func profileResponse(
        tier: String, account: String = "account", organization: String = "organization"
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
                #"{"account":{"uuid":"\#(account)","has_claude_max":true},"organization":{"uuid":"\#(organization)","organization_type":"claude_max","rate_limit_tier":"\#(tier)","subscription_status":"active"}}"#
                    .utf8
            )
        )
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
