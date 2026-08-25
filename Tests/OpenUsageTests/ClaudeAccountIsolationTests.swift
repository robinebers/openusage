import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeAccountIsolationTests: XCTestCase {
    private let path = "/tmp/claude/.credentials.json"

    func testNewLoginBypassesPreviousLoginCacheAndCooldown() async {
        let calls = IsolationCallCounter()
        let fixture = makeFixture(
            credentials: credentials(access: "account-a", refresh: "refresh-a", plan: "pro")
        ) { request in
            if request.headers["Authorization"] == "Bearer account-a" {
                return calls.next() == 1
                    ? Self.usageResponse(percent: 25)
                    : HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
            }
            return Self.usageResponse(percent: 70)
        }

        let initial = await fixture.provider.refresh()
        let limited = await fixture.provider.refresh()
        XCTAssertEqual(sessionUsage(initial), 25)
        XCTAssertEqual(sessionUsage(limited), 25)

        fixture.files.files[path] = credentials(
            access: "account-b", refresh: "refresh-b", plan: "max"
        )
        let switched = await fixture.provider.refresh()

        XCTAssertEqual(switched.plan, "Max")
        XCTAssertEqual(sessionUsage(switched), 70)
        XCTAssertEqual(usageRequests(fixture.http).count, 3)
    }

    func testRefreshTokenChangeSeparatesCacheWhenAccessTokenIsShared() async {
        let calls = IsolationCallCounter()
        let fixture = makeFixture(
            credentials: credentials(access: "shared", refresh: "refresh-a", plan: "pro")
        ) { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return calls.next() == 1
                ? Self.usageResponse(percent: 25)
                : HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let initial = await fixture.provider.refresh()
        XCTAssertEqual(sessionUsage(initial), 25)
        fixture.files.files[path] = credentials(
            access: "shared", refresh: "refresh-b", plan: "max"
        )

        let switched = await fixture.provider.refresh()

        XCTAssertNil(sessionUsage(switched), "account A usage must not cross into account B")
        XCTAssertEqual(status(switched)?.hasPrefix("Rate limited"), true)
    }

    func testValidatedTokenRotationKeepsSameLoginCache() async {
        let fixture = makeFixture(
            credentials: credentials(access: "old-access", refresh: "old-refresh", plan: "pro")
        ) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.headers["Authorization"] == "Bearer old-access" {
                return Self.usageResponse(percent: 25)
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let initial = await fixture.provider.refresh()
        XCTAssertEqual(sessionUsage(initial), 25)
        fixture.files.files[path] = credentials(
            access: "old-access", refresh: "old-refresh", plan: "pro", expiresAt: 1
        )

        let rotated = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(rotated), 25)
        XCTAssertTrue(fixture.files.files[path]?.contains("new-refresh") == true)
    }

    func testReloginDuringTokenRotationCannotBeOverwrittenOrPublished() async {
        let accountA = credentials(
            access: "account-a", refresh: "refresh-a", plan: "pro", expiresAt: 1
        )
        let accountB = credentials(access: "account-b", refresh: "refresh-b", plan: "max")
        let files = FakeFiles([path: accountA])
        let fixture = makeFixture(files: files) { [path] request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                files.files[path] = accountB
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"account-a2","refresh_token":"refresh-a2","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer account-b")
            return Self.usageResponse(percent: 75)
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(fixture.files.files[path], accountB)
        XCTAssertFalse(fixture.http.requests.contains {
            $0.headers["Authorization"] == "Bearer account-a2"
        })
    }

    func testReloginDuringUsageRequestReloadsBeforePublishing() async {
        let accountA = credentials(access: "account-a", refresh: "refresh-a", plan: "pro")
        let accountB = credentials(access: "account-b", refresh: "refresh-b", plan: "max")
        let files = FakeFiles([path: accountA])
        let fixture = makeFixture(files: files) { [path] request in
            if request.headers["Authorization"] == "Bearer account-a" {
                files.files[path] = accountB
                return Self.usageResponse(percent: 25)
            }
            return Self.usageResponse(percent: 75)
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(usageRequests(fixture.http).count, 2)
    }

    func testHigherPriorityLoginAddedDuringUsageRequestWins() async {
        let accountA = credentials(access: "account-a", refresh: "refresh-a", plan: "pro")
        let accountB = credentials(access: "account-b", refresh: "refresh-b", plan: "max")
        let files = FakeFiles([path: accountA])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let service = store.keychainServiceCandidates().first!
        let fixture = makeFixture(files: files, keychain: keychain) { request in
            if request.headers["Authorization"] == "Bearer account-a" {
                keychain.currentUserValues[service] = accountB
                return Self.usageResponse(percent: 25)
            }
            return Self.usageResponse(percent: 75)
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(usageRequests(fixture.http).count, 2)
    }

    func testHigherPriorityLoginAddedDuringTokenRotationPreventsOldWriteAndQuery() async {
        let accountA = credentials(
            access: "account-a", refresh: "refresh-a", plan: "pro", expiresAt: 1
        )
        let accountB = credentials(access: "account-b", refresh: "refresh-b", plan: "max")
        let files = FakeFiles([path: accountA])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let service = store.keychainServiceCandidates().first!
        let fixture = makeFixture(files: files, keychain: keychain) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                keychain.currentUserValues[service] = accountB
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"account-a2","refresh_token":"refresh-a2","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer account-b")
            return Self.usageResponse(percent: 75)
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(files.files[path], accountA)
        XCTAssertFalse(fixture.http.requests.contains {
            $0.headers["Authorization"] == "Bearer account-a2"
        })
    }

    func testEarlierCandidateRotationStillAllowsFallbackToNextSource() async {
        let fileAccount = credentials(access: "file-b", refresh: "file-refresh", plan: "pro")
        let keychainAccount = credentials(
            access: "keychain-a", refresh: "keychain-refresh", plan: "max"
        )
        let files = FakeFiles([path: fileAccount])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let service = store.keychainServiceCandidates().first!
        keychain.currentUserValues[service] = keychainAccount
        let fixture = makeFixture(files: files, keychain: keychain) { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"keychain-a2","refresh_token":"keychain-refresh-2","expires_in":3600}"#.utf8)
                )
            }
            if request.headers["Authorization"] == "Bearer file-b" {
                return Self.usageResponse(percent: 75)
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(
            usageRequests(fixture.http).compactMap { $0.headers["Authorization"] },
            ["Bearer keychain-a", "Bearer keychain-a2", "Bearer file-b"]
        )
    }

    func testAccountVerificationRefreshesExpiredTokenBeforeFetchingUsage() async {
        let fixture = makeFixture(
            credentials: credentials(access: "expired", refresh: "refresh-token", plan: "pro"),
            expectedIdentityKey: "account|organization"
        ) { request in
            switch request.url.path {
            case "/api/oauth/profile":
                guard request.headers["Authorization"] == "Bearer fresh" else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"account":{"uuid":"account"},"organization":{"uuid":"organization"}}"#.utf8)
                )
            case "/v1/oauth/token":
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8)
                )
            case "/api/oauth/usage":
                XCTAssertEqual(request.headers["Authorization"], "Bearer fresh")
                return Self.usageResponse(percent: 42)
            default:
                XCTFail("Unexpected request: \(request.url.path)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(snapshot), 42)
        XCTAssertEqual(fixture.http.requests.map(\.url.path), [
            "/api/oauth/profile", "/v1/oauth/token", "/api/oauth/profile", "/api/oauth/usage"
        ])
        XCTAssertTrue(fixture.files.files[path]?.contains("rotated") == true)
    }

    func testAccountVerificationRateLimitUsesExistingCooldown() async {
        let fixture = makeFixture(
            credentials: credentials(access: "token", refresh: "refresh", plan: "pro"),
            expectedIdentityKey: "account|organization"
        ) { request in
            XCTAssertEqual(request.url.path, "/api/oauth/profile")
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let first = await fixture.provider.refresh()
        let second = await fixture.provider.refresh()

        XCTAssertEqual(status(first)?.hasPrefix("Rate limited"), true)
        XCTAssertEqual(second.warning?.contains("Retrying in ~10m"), true)
        XCTAssertEqual(fixture.http.requests.count, 1)
        XCTAssertTrue(usageRequests(fixture.http).isEmpty)
    }

    func testAccountVerificationOutagesAndMalformedResponsesDoNotClaimLogout() async {
        let cases = [
            (status: 503, body: "", expected: ClaudeUsageError.requestFailed(503).localizedDescription),
            (status: 200, body: "not-json", expected: ClaudeUsageError.invalidResponse.localizedDescription)
        ]
        for scenario in cases {
            let fixture = makeFixture(
                credentials: credentials(access: "token", refresh: "refresh", plan: "pro"),
                expectedIdentityKey: "account|organization"
            ) { request in
                XCTAssertEqual(request.url.path, "/api/oauth/profile")
                return HTTPResponse(
                    statusCode: scenario.status, headers: [:], body: Data(scenario.body.utf8)
                )
            }

            let snapshot = await fixture.provider.refresh()

            if case let .badge(_, message, _, _)? = snapshot.line(label: "Error") {
                XCTAssertEqual(message, scenario.expected)
            } else {
                XCTFail("Missing error for profile status \(scenario.status)")
            }
            XCTAssertTrue(usageRequests(fixture.http).isEmpty)
        }
    }

    private struct Fixture {
        var provider: ClaudeProvider
        var files: FakeFiles
        var http: RoutingHTTPClient
    }

    private func makeFixture(
        credentials: String,
        expectedIdentityKey: String? = nil,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        makeFixture(
            files: FakeFiles([path: credentials]),
            expectedIdentityKey: expectedIdentityKey,
            handler: handler
        )
    }

    private func makeFixture(
        files: FakeFiles,
        keychain: any KeychainAccessing = FakeKeychain(),
        expectedIdentityKey: String? = nil,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        let http = RoutingHTTPClient(handler: handler)
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        return Fixture(
            provider: ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                    files: files,
                    keychain: keychain,
                    expectedIdentityKey: expectedIdentityKey,
                    now: { now }
                ),
                usageClient: ClaudeUsageClient(httpClient: http),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                now: { now },
                pricing: { TestPricing.bundled }
            ),
            files: files,
            http: http
        )
    }

    private func credentials(
        access: String,
        refresh: String,
        plan: String,
        expiresAt: Double = 4_102_444_800_000
    ) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":\#(expiresAt),"subscriptionType":"\#(plan)","scopes":["user:profile"]}}"#
    }

    private nonisolated static func usageResponse(percent: Double) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }

    private func usageRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
    }

    private func sessionUsage(_ snapshot: ProviderSnapshot) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return nil
        }
        return used
    }

    private func status(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.line(label: "Status") else { return nil }
        return text
    }
}

private final class IsolationCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
