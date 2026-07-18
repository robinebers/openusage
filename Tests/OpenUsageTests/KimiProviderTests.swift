import XCTest
@testable import OpenUsage

private let currentOAuthPath = "~/.kimi-code/credentials/kimi-code.json"
private let legacyOAuthPath = "~/.kimi/credentials/kimi-code.json"
private let keyConfigPath = "~/.config/openusage/kimi.json"

private let testNow = Date(timeIntervalSince1970: 1_784_378_000)

/// The live `/coding/v1/usages` shape (verified 2026-07): string-typed numbers, a windowed 5-hour
/// limit, a top-level weekly quota, and the membership level.
private let usageBothJSON = """
{
  "user": {"userId": "user-1", "region": "REGION_OVERSEA", "membership": {"level": "LEVEL_INTERMEDIATE"}, "businessId": ""},
  "usage": {"limit": "100", "used": "5", "remaining": "95", "resetTime": "2026-07-24T09:25:49.415263Z"},
  "limits": [
    {
      "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
      "detail": {"limit": "100", "used": "2", "remaining": "98", "resetTime": "2026-07-18T15:25:49.415263Z"}
    }
  ],
  "parallel": {"limit": "20"},
  "totalQuota": {"limit": "100", "remaining": "99"},
  "authentication": {"method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING"},
  "subType": "TYPE_PURCHASE"
}
"""

private func oauthFileJSON(
    accessToken: String = "kimi-access",
    refreshToken: String = "kimi-refresh",
    expiresAt: Double
) -> String {
    """
    {"access_token":"\(accessToken)","refresh_token":"\(refreshToken)","expires_at":\(expiresAt),"scope":"kimi-code","token_type":"Bearer","expires_in":900}
    """
}

private func data(_ json: String) -> Data {
    Data(json.utf8)
}

private func jsonResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: data(json))
}

private func makeAuthStore(
    files: FakeFiles = FakeFiles(),
    environment: [String: String] = [:],
    now: @escaping @Sendable () -> Date = { testNow }
) -> KimiAuthStore {
    KimiAuthStore(files: files, environment: FakeEnvironment(environment), now: now)
}

// MARK: - Auth store

final class KimiAuthStoreTests: XCTestCase {
    func testLoadsOAuthFromCurrentPath() {
        let files = FakeFiles([currentOAuthPath: oauthFileJSON(expiresAt: 1_784_378_900)])
        let state = makeAuthStore(files: files).loadOAuthState()

        XCTAssertEqual(state?.path, currentOAuthPath)
        XCTAssertEqual(state?.credentials.accessToken, "kimi-access")
        XCTAssertEqual(state?.credentials.refreshToken, "kimi-refresh")
        XCTAssertEqual(state?.credentials.expiresAt, 1_784_378_900)
    }

    func testPrefersCurrentPathOverLegacy() {
        let files = FakeFiles([
            currentOAuthPath: oauthFileJSON(accessToken: "new-cli", expiresAt: 1_784_378_900),
            legacyOAuthPath: oauthFileJSON(accessToken: "old-cli", expiresAt: 1_784_378_900)
        ])
        let state = makeAuthStore(files: files).loadOAuthState()

        XCTAssertEqual(state?.path, currentOAuthPath)
        XCTAssertEqual(state?.credentials.accessToken, "new-cli")
    }

    func testFallsBackToLegacyPath() {
        let files = FakeFiles([legacyOAuthPath: oauthFileJSON(expiresAt: 1_784_378_900)])
        let state = makeAuthStore(files: files).loadOAuthState()

        XCTAssertEqual(state?.path, legacyOAuthPath)
    }

    func testIgnoresCredentialFileWithoutTokens() {
        let files = FakeFiles([currentOAuthPath: #"{"scope":"kimi-code"}"#])
        XCTAssertNil(makeAuthStore(files: files).loadOAuthState())
    }

    func testNeedsRefreshOnlyNearExpiry() {
        let store = makeAuthStore()
        let fresh = KimiOAuthCredentials(accessToken: "a", expiresAt: testNow.timeIntervalSince1970 + 600)
        let nearExpiry = KimiOAuthCredentials(accessToken: "a", expiresAt: testNow.timeIntervalSince1970 + 200)
        let missingExpiry = KimiOAuthCredentials(accessToken: "a")
        let missingToken = KimiOAuthCredentials(refreshToken: "r", expiresAt: testNow.timeIntervalSince1970 + 600)

        XCTAssertFalse(store.needsRefresh(fresh))
        XCTAssertTrue(store.needsRefresh(nearExpiry))
        XCTAssertTrue(store.needsRefresh(missingExpiry))
        XCTAssertTrue(store.needsRefresh(missingToken))
    }

    func testAPIKeyPrefersConfigFileOverEnvironment() {
        let files = FakeFiles([keyConfigPath: #"{"apiKey":"from-config"}"#])
        let store = makeAuthStore(files: files, environment: ["KIMI_API_KEY": "from-env"])

        XCTAssertEqual(store.loadAPIKey(), "from-config")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testSavePersistsCredentialsToSourcePath() throws {
        let files = FakeFiles([currentOAuthPath: oauthFileJSON(expiresAt: 1)])
        let store = makeAuthStore(files: files)
        var state = try XCTUnwrap(store.loadOAuthState())
        state.credentials.accessToken = "rotated-access"
        state.credentials.refreshToken = "rotated-refresh"

        try store.save(state)

        let persisted = try XCTUnwrap(store.loadOAuth(at: currentOAuthPath))
        XCTAssertEqual(persisted.credentials.accessToken, "rotated-access")
        XCTAssertEqual(persisted.credentials.refreshToken, "rotated-refresh")
    }
}

// MARK: - Mapper

final class KimiUsageMapperTests: XCTestCase {
    func testMapsSessionWeeklyAndPlan() throws {
        let mapped = try KimiUsageMapper.map(data(usageBothJSON))

        XCTAssertEqual(mapped.plan, "Intermediate")
        XCTAssertEqual(mapped.lines.count, 2)

        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _) = mapped.lines[0] else {
            return XCTFail("expected a session progress line, got \(mapped.lines[0])")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 2, accuracy: 0.001)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(periodMs, 300 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(resetsAt).timeIntervalSince1970, 1_784_388_349.415, accuracy: 0.01)

        guard case .progress(let weeklyLabel, let weeklyUsed, _, _, let weeklyResets, let weeklyPeriod, _) = mapped.lines[1] else {
            return XCTFail("expected a weekly progress line, got \(mapped.lines[1])")
        }
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 5, accuracy: 0.001)
        XCTAssertNil(weeklyPeriod)
        XCTAssertEqual(try XCTUnwrap(weeklyResets).timeIntervalSince1970, 1_784_885_149.415, accuracy: 0.01)
    }

    func testDerivesUsedFromRemaining() throws {
        let json = """
        {"usage": {"limit": "200", "remaining": "150", "resetTime": "2026-07-24T09:25:49Z"}}
        """
        let mapped = try KimiUsageMapper.map(data(json))

        guard case .progress(_, let used, _, _, _, _, _) = mapped.lines[0] else {
            return XCTFail("expected a progress line, got \(mapped.lines[0])")
        }
        XCTAssertEqual(used, 25, accuracy: 0.001)
    }

    func testSkipsWeeklyIdenticalToSession() throws {
        let json = """
        {
          "usage": {"limit": "100", "used": "40", "resetTime": "2026-07-24T09:25:49Z"},
          "limits": [
            {
              "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
              "detail": {"limit": "100", "used": "40", "resetTime": "2026-07-24T09:25:49Z"}
            }
          ]
        }
        """
        let mapped = try KimiUsageMapper.map(data(json))

        XCTAssertEqual(mapped.lines.map(\.label), ["Session"])
    }

    func testFallsBackToLongestWindowWhenUsageQuotaMissing() throws {
        let json = """
        {
          "limits": [
            {
              "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
              "detail": {"limit": "100", "used": "10"}
            },
            {
              "window": {"duration": 7, "timeUnit": "TIME_UNIT_DAY"},
              "detail": {"limit": "100", "used": "60"}
            }
          ]
        }
        """
        let mapped = try KimiUsageMapper.map(data(json))

        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly"])
        guard case .progress(_, let used, _, _, _, let periodMs, _) = mapped.lines[1] else {
            return XCTFail("expected a weekly progress line, got \(mapped.lines[1])")
        }
        XCTAssertEqual(used, 60, accuracy: 0.001)
        XCTAssertEqual(periodMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testEmptyLimitsMapsToNoDataBadge() throws {
        let mapped = try KimiUsageMapper.map(data(#"{"limits": []}"#))

        XCTAssertEqual(mapped.lines, [.noUsageData])
        XCTAssertNil(mapped.plan)
    }

    func testQuotaWithoutUsageValuesThrows() {
        let json = """
        {"usage": {"limit": "100", "resetTime": "2026-07-24T09:25:49Z"}}
        """
        XCTAssertThrowsError(try KimiUsageMapper.map(data(json))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }

    func testUnrecognizedPayloadThrows() {
        XCTAssertThrowsError(try KimiUsageMapper.map(data(#"{"ok": true}"#))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try KimiUsageMapper.map(data("not-json"))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }
}

// MARK: - Provider

@MainActor
final class KimiProviderTests: XCTestCase {
    private func makeProvider(
        files: FakeFiles,
        environment: [String: String] = [:],
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> (KimiProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let provider = KimiProvider(
            authStore: makeAuthStore(files: files, environment: environment),
            usageClient: KimiUsageClient(http: http),
            now: { testNow }
        )
        return (provider, http)
    }

    func testRefreshWithAPIKeySendsBearerAndMaps() async throws {
        let files = FakeFiles([keyConfigPath: #"{"apiKey":"kimi-key"}"#])
        let (provider, http) = makeProvider(files: files) { request in
            XCTAssertEqual(request.url, KimiUsageClient.usageURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer kimi-key")
            return jsonResponse(usageBothJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Intermediate")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testAPIKeyWinsOverCLILogin() async throws {
        let files = FakeFiles([
            keyConfigPath: #"{"apiKey":"kimi-key"}"#,
            currentOAuthPath: oauthFileJSON(expiresAt: 0)
        ])
        let (provider, http) = makeProvider(files: files) { request in
            jsonResponse(usageBothJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer kimi-key")
    }

    func testFreshCLITokenSkipsRefresh() async throws {
        let files = FakeFiles([
            currentOAuthPath: oauthFileJSON(expiresAt: testNow.timeIntervalSince1970 + 600)
        ])
        let (provider, http) = makeProvider(files: files) { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer kimi-access")
            return jsonResponse(usageBothJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
    }

    func testExpiredCLITokenRefreshesPersistsAndFetches() async throws {
        let files = FakeFiles([
            currentOAuthPath: oauthFileJSON(expiresAt: testNow.timeIntervalSince1970 - 60)
        ])
        let (provider, http) = makeProvider(files: files) { request in
            if request.url == KimiUsageClient.refreshURL {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("client_id=\(KimiUsageClient.clientID)"))
                XCTAssertTrue(body.contains("refresh_token=kimi-refresh"))
                return jsonResponse("""
                {"access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 900, "scope": "kimi-code", "token_type": "Bearer"}
                """)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access")
            return jsonResponse(usageBothJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.refreshURL, KimiUsageClient.usageURL])

        let persisted = try XCTUnwrap(makeAuthStore(files: files).loadOAuth(at: currentOAuthPath))
        XCTAssertEqual(persisted.credentials.accessToken, "rotated-access")
        XCTAssertEqual(persisted.credentials.refreshToken, "rotated-refresh")
        XCTAssertEqual(try XCTUnwrap(persisted.credentials.expiresAt), testNow.timeIntervalSince1970 + 900, accuracy: 0.001)
    }

    func testUsage401RefreshesAndRetriesOnce() async throws {
        let files = FakeFiles([
            currentOAuthPath: oauthFileJSON(expiresAt: testNow.timeIntervalSince1970 + 600)
        ])
        let usageCalls = Counter()
        let (provider, http) = makeProvider(files: files) { request in
            if request.url == KimiUsageClient.refreshURL {
                return jsonResponse(#"{"access_token": "rotated-access", "expires_in": 900}"#)
            }
            if await usageCalls.increment() == 1 {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access")
            return jsonResponse(usageBothJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            http.requests.map(\.url),
            [KimiUsageClient.usageURL, KimiUsageClient.refreshURL, KimiUsageClient.usageURL]
        )
    }

    func testRejectedRefreshReportsSessionExpired() async {
        let files = FakeFiles([
            currentOAuthPath: oauthFileJSON(expiresAt: testNow.timeIntervalSince1970 - 60)
        ])
        let (provider, _) = makeProvider(files: files) { request in
            HTTPResponse(statusCode: 401, headers: [:], body: data(#"{"error": "unauthorized"}"#))
        }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(snapshot.lines.first, .badge(
            label: MetricLine.errorBadgeLabel,
            text: KimiAuthError.sessionExpired.localizedDescription,
            colorHex: "#EF4444"
        ))
    }

    func testNoCredentialsReportsNotLoggedIn() async {
        let (provider, http) = makeProvider(files: FakeFiles()) { _ in
            XCTFail("no request expected without credentials")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testHasLocalCredentialsMirrorsRefreshSources() async {
        let none = makeProvider(files: FakeFiles()) { _ in jsonResponse(usageBothJSON) }.0
        let withOAuth = makeProvider(
            files: FakeFiles([currentOAuthPath: oauthFileJSON(expiresAt: 1)])
        ) { _ in jsonResponse(usageBothJSON) }.0
        let withKey = makeProvider(
            files: FakeFiles(),
            environment: ["KIMI_API_KEY": "kimi-key"]
        ) { _ in jsonResponse(usageBothJSON) }.0

        let noneHas = await none.hasLocalCredentials()
        let oauthHas = await withOAuth.hasLocalCredentials()
        let keyHas = await withKey.hasLocalCredentials()

        XCTAssertFalse(noneHas)
        XCTAssertTrue(oauthHas)
        XCTAssertTrue(keyHas)
    }
}

/// A tiny async-safe call counter for routing handlers that must vary by attempt.
private actor Counter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
