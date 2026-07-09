import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeRefreshBoundaryTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
    private let credentialsPath = "/tmp/claude/.credentials.json"

    func testRefreshTransportFailureKeepsNetworkClassificationAndSavedCredentials() async {
        let fixture = makeFixture { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                throw URLError(.notConnectedToInternet)
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(errorText(snapshot), ProviderUsageErrorText.connectionFailed)
        XCTAssertEqual(fixture.files.files[credentialsPath], fixture.originalCredentials)
    }

    func testMalformedRefreshResponseKeepsDecodingClassificationAndSavedCredentials() async {
        let fixture = makeFixture { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertEqual(errorText(snapshot), ProviderUsageErrorText.invalidResponse)
        XCTAssertEqual(fixture.files.files[credentialsPath], fixture.originalCredentials)
    }

    func testInvalidRefreshFieldsNeverOverwriteSavedCredentials() async {
        let invalidBodies = [
            #"{"access_token":"   ","refresh_token":"replacement","expires_in":3600}"#,
            #"{"access_token":"replacement","refresh_token":"replacement","expires_in":0}"#,
            #"{"access_token":"replacement","refresh_token":"replacement","expires_in":-60}"#,
            #"{"access_token":"replacement","refresh_token":"replacement","expires_in":1e308}"#
        ]

        for body in invalidBodies {
            let fixture = makeFixture { request in
                if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
                }
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }

            let snapshot = await fixture.provider.refresh()

            XCTAssertEqual(snapshot.errorCategory, .decoding, body)
            XCTAssertEqual(errorText(snapshot), ProviderUsageErrorText.invalidResponse, body)
            XCTAssertEqual(fixture.files.files[credentialsPath], fixture.originalCredentials, body)
        }
    }

    func testValidRotationTrimsTokenPreservesBlankOptionalRefreshAndClearsOldExpiry() async {
        let fixture = makeFixture { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":" replacement-access ","refresh_token":"   "}"#.utf8)
                )
            }
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                XCTAssertEqual(request.headers["Authorization"], "Bearer replacement-access")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()
        let saved = ClaudeAuthStore.parseCredentials(fixture.files.files[credentialsPath] ?? "")?.claudeAiOauth

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(saved?.accessToken, "replacement-access")
        XCTAssertEqual(saved?.refreshToken, "old-refresh")
        XCTAssertNil(saved?.expiresAt)
    }

    func testConcurrentReloginReloadsCurrentAccountWithoutPublishingEarlierRefresh() async {
        let originalCredentials = #"{"claudeAiOauth":{"accessToken":"account-a","refreshToken":"refresh-a","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let replacementCredentials = #"{"claudeAiOauth":{"accessToken":"account-b","refreshToken":"refresh-b","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#
        let path = credentialsPath
        let files = FakeFiles([path: originalCredentials])
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                // Simulate Claude Code completing a new login while OpenUsage awaits account A's
                // refresh response. The older A2 rotation must never overwrite this newer account B.
                files.files[path] = replacementCredentials
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"account-a2","refresh_token":"refresh-a2","expires_in":3600}"#.utf8)
                )
            }
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                XCTAssertEqual(request.headers["Authorization"], "Bearer account-b")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":75,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let fixedNow = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { fixedNow }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(files.files[credentialsPath], replacementCredentials)
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("expected current account's Session usage")
        }
        XCTAssertEqual(used, 75)
        XCTAssertFalse(http.requests.contains { $0.headers["Authorization"] == "Bearer account-a2" })
    }

    func testCredentialComparisonAndWriteRunOffMainThread() async {
        let credentials = #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let files = ThreadRecordingFiles([credentialsPath: credentials])
        let fixedNow = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { fixedNow }
            ),
            usageClient: ClaudeUsageClient(httpClient: RoutingHTTPClient { request in
                if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"access_token":"replacement","refresh_token":"replacement-refresh","expires_in":3600}"#.utf8)
                    )
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(files.lastWriteWasOnMainThread, false)
    }

    func testRepeatedCredentialChangesStopAfterOneReloadWithoutPublishingStaleUsage() async {
        let accountA = #"{"claudeAiOauth":{"accessToken":"account-a","refreshToken":"refresh-a","expiresAt":1,"scopes":["user:profile"]}}"#
        let accountB = #"{"claudeAiOauth":{"accessToken":"account-b","refreshToken":"refresh-b","expiresAt":1,"scopes":["user:profile"]}}"#
        let accountC = #"{"claudeAiOauth":{"accessToken":"account-c","refreshToken":"refresh-c","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        let path = credentialsPath
        let files = FakeFiles([path: accountA])
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                if files.files[path] == accountA {
                    files.files[path] = accountB
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"access_token":"account-a2","refresh_token":"refresh-a2","expires_in":3600}"#.utf8)
                    )
                }
                files.files[path] = accountC
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"account-b2","refresh_token":"refresh-b2","expires_in":3600}"#.utf8)
                )
            }
            XCTFail("a repeatedly changing login must not reach live usage")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let fixedNow = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { fixedNow }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(errorText(snapshot), ClaudeAuthError.credentialsChanged.localizedDescription)
        XCTAssertEqual(files.files[path], accountC)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(http.requests.allSatisfy { $0.url.absoluteString.hasSuffix("/v1/oauth/token") })
    }

    func testExpiredCredentialWithWhitespaceRefreshTokenSkipsProactiveRefresh() async {
        let credentials = #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"   ","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let fixture = makeFixture(originalCredentials: credentials) { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(fixture.http.requests.contains { $0.url.absoluteString.hasSuffix("/v1/oauth/token") })
        XCTAssertEqual(
            fixture.http.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }.count,
            1
        )
    }

    func testUsage401WithWhitespaceRefreshTokenReportsExpiredWithoutRefreshRequest() async {
        let credentials = #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"   ","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let fixture = makeFixture(originalCredentials: credentials) { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(errorText(snapshot), ClaudeAuthError.tokenExpired.localizedDescription)
        XCTAssertFalse(fixture.http.requests.contains { $0.url.absoluteString.hasSuffix("/v1/oauth/token") })
    }

    func testRefreshClientInvalidHTTPResponseKeepsDecodingClassification() async {
        let fixture = makeFixture { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                throw HTTPClientError.invalidResponse
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertEqual(errorText(snapshot), ProviderUsageErrorText.invalidResponse)
        XCTAssertEqual(fixture.files.files[credentialsPath], fixture.originalCredentials)
    }

    func testMalformedCustomOAuthURLKeepsConfigurationClassification() async {
        let credentials = #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let fixture = makeFixture(
            originalCredentials: credentials,
            environmentValues: ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "not-a-url?token=top-secret"]
        ) { _ in
            XCTFail("invalid endpoint configuration must fail before an HTTP request")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(
            errorText(snapshot),
            ClaudeAuthError.invalidOAuthURL.localizedDescription
        )
        XCTAssertFalse(errorText(snapshot)?.contains("top-secret") == true)
        XCTAssertTrue(fixture.http.requests.isEmpty)
    }

    private struct Fixture {
        var provider: ClaudeProvider
        var files: FakeFiles
        var http: RoutingHTTPClient
        var originalCredentials: String
    }

    private func makeFixture(
        originalCredentials: String? = nil,
        environmentValues: [String: String] = [:],
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        let originalCredentials = originalCredentials
            ?? #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let files = FakeFiles([credentialsPath: originalCredentials])
        let fixedNow = now
        var environment = ["CLAUDE_CONFIG_DIR": "/tmp/claude"]
        environment.merge(environmentValues) { _, override in override }
        let http = RoutingHTTPClient(handler: handler)
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(environment),
                files: files,
                keychain: FakeKeychain(),
                now: { fixedNow }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )
        return Fixture(provider: provider, files: files, http: http, originalCredentials: originalCredentials)
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(let label, let text, _, _) = snapshot.lines.first,
              label == MetricLine.errorBadgeLabel
        else {
            return nil
        }
        return text
    }
}

private final class ThreadRecordingFiles: TextFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private var writeWasOnMainThread: Bool?

    init(_ files: [String: String]) {
        self.files = files
    }

    var lastWriteWasOnMainThread: Bool? {
        lock.withLock { writeWasOnMainThread }
    }

    func exists(_ path: String) -> Bool {
        lock.withLock { files[path] != nil }
    }

    func readText(_ path: String) throws -> String {
        lock.withLock { files[path] ?? "" }
    }

    func writeText(_ path: String, _ text: String) throws {
        lock.withLock {
            writeWasOnMainThread = Thread.isMainThread
            files[path] = text
        }
    }

    func remove(_ path: String) throws {
        lock.withLock { _ = files.removeValue(forKey: path) }
    }
}
