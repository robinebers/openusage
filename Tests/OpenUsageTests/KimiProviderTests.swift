import XCTest
@testable import OpenUsage

// MARK: - Auth store

final class KimiAuthStoreTests: XCTestCase {
    private let codeHomeCredentials = "~/.kimi-code/credentials/kimi-code.json"
    private let shareHomeCredentials = "~/.kimi/credentials/kimi-code.json"

    func testLoadsFromTheShippedCLIHome() throws {
        let store = makeStore(files: FakeFiles([codeHomeCredentials: credentialsJSON(accessToken: "code-home")]))

        let state = try store.load()

        XCTAssertEqual(state?.home, "~/.kimi-code")
        XCTAssertEqual(state?.oauth.accessToken, "code-home")
        XCTAssertEqual(state?.oauth.refreshToken, "refresh-token")
        XCTAssertEqual(state?.oauth.expiresAt, 1_800_000_900)
        XCTAssertEqual(state?.oauth.expiresIn, 900)
        XCTAssertEqual(state?.oauth.scope, "kimi-code")
        XCTAssertEqual(state?.oauth.tokenType, "Bearer")
    }

    /// Upstream still writes to `~/.kimi`; the shipped CLI writes to `~/.kimi-code`. Both layouts are in
    /// the wild, so a user on either one is detected.
    func testFallsBackToTheUpstreamShareHome() throws {
        let store = makeStore(files: FakeFiles([shareHomeCredentials: credentialsJSON(accessToken: "share-home")]))

        let state = try store.load()

        XCTAssertEqual(state?.home, "~/.kimi")
        XCTAssertEqual(state?.oauth.accessToken, "share-home")
    }

    func testPrefersTheShippedHomeWhenBothExist() throws {
        let store = makeStore(files: FakeFiles([
            codeHomeCredentials: credentialsJSON(accessToken: "code-home"),
            shareHomeCredentials: credentialsJSON(accessToken: "share-home")
        ]))

        XCTAssertEqual(try store.load()?.oauth.accessToken, "code-home")
    }

    func testEnvironmentOverrideWins() throws {
        let store = makeStore(
            files: FakeFiles([
                "/custom/kimi/credentials/kimi-code.json": credentialsJSON(accessToken: "custom-home"),
                codeHomeCredentials: credentialsJSON(accessToken: "code-home")
            ]),
            environment: FakeEnvironment(["KIMI_CODE_HOME": "/custom/kimi/"])
        )

        let state = try store.load()

        XCTAssertEqual(state?.home, "/custom/kimi")
        XCTAssertEqual(state?.oauth.accessToken, "custom-home")
    }

    func testMissingCredentialsReturnsNilRatherThanThrowing() throws {
        XCTAssertNil(try makeStore(files: FakeFiles()).load())
    }

    /// A file that exists but can't be parsed is a real problem, not a logout — it has to surface as an
    /// error so the card explains itself instead of quietly reading "not logged in".
    func testUnreadableCredentialsThrows() {
        let store = makeStore(files: FakeFiles([codeHomeCredentials: "{ not json"]))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? KimiAuthError, .invalidCredentials)
        }
    }

    func testBlankAccessTokenIsNotUsableCredentials() {
        let store = makeStore(files: FakeFiles([codeHomeCredentials: credentialsJSON(accessToken: "   ")]))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? KimiAuthError, .invalidCredentials)
        }
    }

    /// The local-only probe behind first-run detection: a present-but-broken file still counts, so
    /// `refresh()` gets to report the real problem instead of the provider staying invisibly off.
    func testHasCredentialsFileCountsAnUnreadableFile() {
        XCTAssertFalse(makeStore(files: FakeFiles()).hasCredentialsFile())
        XCTAssertTrue(makeStore(files: FakeFiles([codeHomeCredentials: "{ not json"])).hasCredentialsFile())
    }

    /// `expires_at` is epoch **seconds** here (Claude's is milliseconds), against a 5-minute buffer.
    func testNeedsRefreshUsesSecondsAgainstTheFiveMinuteBuffer() {
        let store = makeStore(files: FakeFiles())

        XCTAssertFalse(store.needsRefresh(oauth(expiresAt: 1_800_000_000 + 301)))
        XCTAssertTrue(store.needsRefresh(oauth(expiresAt: 1_800_000_000 + 300)))
        XCTAssertTrue(store.needsRefresh(oauth(expiresAt: 1_800_000_000 - 60)))
    }

    /// Rotating another tool's refresh token on a guess is the one thing worth avoiding, so a credential
    /// with no expiry is left alone — the 401 retry path still recovers.
    func testNeedsRefreshIsFalseWithoutAnExpiry() {
        XCTAssertFalse(makeStore(files: FakeFiles()).needsRefresh(oauth(expiresAt: nil)))
    }

    func testSaveMergesIntoTheLiveFileAndKeepsUnknownKeys() throws {
        let files = FakeFiles([
            codeHomeCredentials: """
            {"access_token":"old","refresh_token":"old-refresh","expires_at":1,"some_future_field":"keep me"}
            """
        ])
        let lock = FakeFileLock()
        let store = makeStore(files: files, lock: lock)
        var state = try XCTUnwrap(store.load())
        state.oauth.accessToken = "rotated"
        state.oauth.refreshToken = "rotated-refresh"
        state.oauth.expiresAt = 1_800_000_900

        try store.save(state)

        let written = try XCTUnwrap(KimiAuthStore.parseJSONObject(files.files[codeHomeCredentials] ?? ""))
        XCTAssertEqual(written["access_token"] as? String, "rotated")
        XCTAssertEqual(written["refresh_token"] as? String, "rotated-refresh")
        XCTAssertEqual(written["expires_at"] as? Double, 1_800_000_900)
        XCTAssertEqual(written["some_future_field"] as? String, "keep me")
        XCTAssertEqual(lock.lockedPaths, ["~/.kimi-code/credentials/kimi-code.lock"])
    }

    /// Rebuilding a corrupt-but-present file from memory would discard whatever else it held, so the save
    /// refuses instead.
    func testSaveRefusesToRebuildACorruptFile() throws {
        let files = FakeFiles([codeHomeCredentials: credentialsJSON(accessToken: "good")])
        let store = makeStore(files: files)
        let state = try XCTUnwrap(store.load())
        files.files[codeHomeCredentials] = "{ not json"

        XCTAssertThrowsError(try store.save(state)) { error in
            XCTAssertEqual(error as? KimiAuthError, .invalidCredentials)
        }
        XCTAssertEqual(files.files[codeHomeCredentials], "{ not json")
    }

    func testReloadLiveReadsOnlyTheGivenHome() throws {
        let files = FakeFiles([codeHomeCredentials: credentialsJSON(accessToken: "first")])
        let store = makeStore(files: files)
        files.files[codeHomeCredentials] = credentialsJSON(accessToken: "rotated-by-the-cli")

        XCTAssertEqual(store.reloadLive(home: "~/.kimi-code")?.oauth.accessToken, "rotated-by-the-cli")
        XCTAssertNil(store.reloadLive(home: "~/.kimi"))
    }

    // MARK: Helpers

    private func makeStore(
        files: FakeFiles,
        environment: FakeEnvironment = FakeEnvironment(),
        lock: FakeFileLock = FakeFileLock()
    ) -> KimiAuthStore {
        KimiAuthStore(
            files: files,
            environment: environment,
            lock: lock,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func oauth(expiresAt: Double?) -> KimiOAuth {
        KimiOAuth(accessToken: "token", refreshToken: "refresh", expiresAt: expiresAt, expiresIn: 900)
    }

    private func credentialsJSON(accessToken: String) -> String {
        """
        {"access_token":"\(accessToken)","refresh_token":"refresh-token","expires_at":1800000900,\
        "expires_in":900,"scope":"kimi-code","token_type":"Bearer"}
        """
    }
}

// MARK: - Usage mapper

final class KimiUsageMapperTests: XCTestCase {
    /// The payload recorded from a live `GET /coding/v1/usages`, verbatim — including the numbers arriving
    /// as JSON strings and the 5-hour window carrying `used` with no `remaining`.
    private let livePayload: [String: Any] = [
        "user": [
            "userId": "abc123",
            "region": "REGION_OVERSEA",
            "membership": ["level": "LEVEL_INTERMEDIATE"],
            "businessId": ""
        ],
        "limited": true,
        "usage": [
            "limit": "100",
            "used": "41",
            "remaining": "59",
            "resetTime": "2026-07-31T07:54:26Z"
        ],
        "limits": [
            [
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": "100", "used": "100", "resetTime": "2026-07-24T17:54:26Z"]
            ]
        ],
        "parallel": ["limit": "20"],
        "subType": "TYPE_PURCHASE"
    ]

    func testMapsTheLivePayload() throws {
        let mapped = try KimiUsageMapper.mapUsage(livePayload)

        XCTAssertEqual(mapped.plan, "Intermediate")
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly"])

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 100)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.periodDurationMs, MetricPeriod.sessionMs)
        XCTAssertEqual(session.resetsAt, OpenUsageISO8601.date(from: "2026-07-24T17:54:26Z"))

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 41)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.periodDurationMs, MetricPeriod.weekMs)
        XCTAssertEqual(weekly.resetsAt, OpenUsageISO8601.date(from: "2026-07-31T07:54:26Z"))
    }

    /// The 5-hour window reports `used`; the weekly pool reports both. A block with only `remaining` still
    /// has to map, since either field alone is enough to know the meter.
    func testDerivesUsedFromRemainingWhenUsedIsAbsent() throws {
        var payload = livePayload
        payload["usage"] = ["limit": "100", "remaining": "70", "resetTime": "2026-07-31T07:54:26Z"]

        let mapped = try KimiUsageMapper.mapUsage(payload)

        XCTAssertEqual(try XCTUnwrap(progress(mapped.lines, "Weekly")).used, 30)
    }

    /// A measured zero stays zero (a fresh window reads "Not started"), rather than collapsing to no data.
    func testZeroUsageIsAMeasuredZero() throws {
        var payload = livePayload
        payload["limits"] = [
            [
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": "100", "used": "0", "remaining": "100", "resetTime": "2026-07-24T17:54:26Z"]
            ]
        ]

        let mapped = try KimiUsageMapper.mapUsage(payload)

        XCTAssertEqual(try XCTUnwrap(progress(mapped.lines, "Session")).used, 0)
    }

    /// The ratio is taken against the reported `limit`, so a future change of scale can't silently
    /// misreport the meter as a raw count.
    func testScalesAgainstTheReportedLimit() throws {
        var payload = livePayload
        payload["usage"] = ["limit": "500", "used": "125", "resetTime": "2026-07-31T07:54:26Z"]

        let mapped = try KimiUsageMapper.mapUsage(payload)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 25)
        XCTAssertEqual(weekly.limit, 100)
    }

    func testIgnoresRateWindowsThatArentTheFiveHourPool() throws {
        var payload = livePayload
        payload["limits"] = [
            [
                "window": ["duration": 7, "timeUnit": "TIME_UNIT_DAY"],
                "detail": ["limit": "100", "used": "10"]
            ]
        ]

        let mapped = try KimiUsageMapper.mapUsage(payload)

        XCTAssertEqual(mapped.lines.map(\.label), ["Weekly"])
    }

    func testAcceptsAnHourSpelledFiveHourWindow() throws {
        var payload = livePayload
        payload["limits"] = [
            [
                "window": ["duration": 5, "timeUnit": "TIME_UNIT_HOUR"],
                "detail": ["limit": "100", "used": "80"]
            ]
        ]

        let mapped = try KimiUsageMapper.mapUsage(payload)

        XCTAssertEqual(try XCTUnwrap(progress(mapped.lines, "Session")).used, 80)
    }

    /// A membership level OpenUsage has never seen still produces a readable plan name, because the label
    /// is derived from the enum rather than looked up in a hardcoded table.
    func testDerivesPlanFromAnUnknownMembershipLevel() throws {
        var payload = livePayload
        payload["user"] = ["membership": ["level": "LEVEL_SUPER_DUPER"]]

        XCTAssertEqual(try KimiUsageMapper.mapUsage(payload).plan, "Super Duper")
    }

    func testMissingMembershipLeavesThePlanUnset() throws {
        var payload = livePayload
        payload.removeValue(forKey: "user")

        XCTAssertNil(try KimiUsageMapper.mapUsage(payload).plan)
    }

    func testThrowsWhenNoQuotaIsPresent() {
        XCTAssertThrowsError(try KimiUsageMapper.mapUsage(["user": ["membership": ["level": "LEVEL_BASIC"]]])) { error in
            XCTAssertEqual(error as? KimiUsageError, .quotaUnavailable)
        }
    }

    func testThrowsOnAnUnparseableBody() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))

        XCTAssertThrowsError(try KimiUsageMapper.mapUsageResponse(response)) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) =
                lines.first(where: { $0.label == label })
        else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

// MARK: - Provider

@MainActor
final class KimiProviderTests: XCTestCase {
    private let credentialsPath = "~/.kimi-code/credentials/kimi-code.json"
    private let usageURL = "https://api.kimi.com/coding/v1/usages"
    private let tokenURL = "https://auth.kimi.com/api/oauth/token"

    func testFetchesUsageWithAFreshToken() async throws {
        let httpClient = QueueHTTPClient(responses: [usageResponse()])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_003_600)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Intermediate")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [usageURL])
        XCTAssertEqual(httpClient.requests.first?.headers["Authorization"], "Bearer access-token")
    }

    /// Access tokens live ~15 minutes, so refreshing before the fetch is the normal path.
    func testRefreshesPreemptivelyWhenTheTokenIsNearlyExpired() async throws {
        let httpClient = QueueHTTPClient(responses: [refreshResponse(), usageResponse()])
        let files = FakeFiles([credentialsPath: credentialsJSON(expiresAt: 1_800_000_060)])
        let provider = makeProvider(httpClient: httpClient, files: files)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [tokenURL, usageURL])
        XCTAssertEqual(httpClient.requests.last?.headers["Authorization"], "Bearer rotated-access")

        let body = String(decoding: httpClient.requests.first?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("refresh_token=refresh-token"), body)
        XCTAssertTrue(body.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"), body)
    }

    /// The rotated pair has to land in the CLI's own file, or the next attempt sends a refresh token the
    /// server has already retired — which is how a user gets logged out of Kimi.
    func testPersistsTheRotatedTokenPair() async throws {
        let files = FakeFiles([credentialsPath: credentialsJSON(expiresAt: 1_800_000_060)])
        let provider = makeProvider(
            httpClient: QueueHTTPClient(responses: [refreshResponse(), usageResponse()]),
            files: files
        )

        _ = await provider.refresh()

        let written = try XCTUnwrap(KimiAuthStore.parseJSONObject(files.files[credentialsPath] ?? ""))
        XCTAssertEqual(written["access_token"] as? String, "rotated-access")
        XCTAssertEqual(written["refresh_token"] as? String, "rotated-refresh")
        XCTAssertEqual(written["expires_at"] as? Double, 1_800_000_900)
    }

    /// A token the `kimi` CLI rotated out from under us is adopted instead of being refreshed from our
    /// stale copy, which would send an already-retired refresh token.
    func testAdoptsATokenTheCLIRotatedInsteadOfRefreshing() async throws {
        let httpClient = QueueHTTPClient(responses: [usageResponse()])
        let files = FakeFiles([credentialsPath: credentialsJSON(expiresAt: 1_800_000_060)])
        let provider = makeProvider(httpClient: httpClient, files: files)
        files.files[credentialsPath] = credentialsJSON(
            accessToken: "cli-rotated",
            expiresAt: 1_800_003_600
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [usageURL])
        XCTAssertEqual(httpClient.requests.first?.headers["Authorization"], "Bearer cli-rotated")
    }

    func testRefreshesAndRetriesOnceOnA401() async throws {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            refreshResponse(),
            usageResponse()
        ])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_003_600)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [usageURL, tokenURL, usageURL])
    }

    func testASecondUnauthorizedIsAHardAuthFailure() async {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            refreshResponse(),
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
        ])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_003_600)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(errorText(snapshot))
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testInvalidGrantReportsAnExpiredSession() async {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        ])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_000_060)

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot), KimiAuthError.sessionExpired.errorDescription)
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    /// A 400 with no recognized OAuth code is usually a proxy or gateway page, not an expiry the user can
    /// fix by logging in again — so it reports the status instead.
    func testUnrecognized400ReportsTheHTTPStatus() async {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>gateway</html>".utf8))
        ])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_000_060)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http4xx)
    }

    func testNoCredentialsReportsNotLoggedIn() async {
        let provider = makeProvider(httpClient: QueueHTTPClient(), files: FakeFiles())

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot), KimiAuthError.notLoggedIn.errorDescription)
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testUnreadableCredentialsReportsInvalidAuthRatherThanLoggedOut() async {
        let provider = makeProvider(
            httpClient: QueueHTTPClient(),
            files: FakeFiles([credentialsPath: "{ not json"])
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testServerErrorReportsTheStatus() async {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 503, headers: [:], body: Data("{}".utf8))
        ])
        let provider = makeProvider(httpClient: httpClient, expiresAt: 1_800_003_600)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testHasLocalCredentialsMirrorsTheCredentialFile() async {
        let present = makeProvider(
            httpClient: QueueHTTPClient(),
            files: FakeFiles([credentialsPath: credentialsJSON(expiresAt: 1_800_003_600)])
        )
        let absent = makeProvider(httpClient: QueueHTTPClient(), files: FakeFiles())

        let foundPresent = await present.hasLocalCredentials()
        let foundAbsent = await absent.hasLocalCredentials()
        XCTAssertTrue(foundPresent)
        XCTAssertFalse(foundAbsent)
    }

    func testDeclaresTheSessionWindowOnTheSessionTileOnly() {
        let descriptors = makeProvider(httpClient: QueueHTTPClient(), files: FakeFiles()).widgetDescriptors

        XCTAssertEqual(descriptors.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertTrue(descriptors.first { $0.id == "kimi.session" }?.sample.isSessionWindow == true)
        XCTAssertFalse(descriptors.first { $0.id == "kimi.weekly" }?.sample.isSessionWindow == true)
    }

    // MARK: Helpers

    /// Error snapshots carry their user-facing copy as a badge line, not a dedicated property.
    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.line(label: MetricLine.errorBadgeLabel) else {
            return nil
        }
        return text
    }

    private func makeProvider(
        httpClient: QueueHTTPClient,
        files: FakeFiles? = nil,
        expiresAt: Double = 1_800_003_600
    ) -> KimiProvider {
        let files = files ?? FakeFiles([credentialsPath: credentialsJSON(expiresAt: expiresAt)])
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files,
                environment: FakeEnvironment(),
                lock: FakeFileLock(),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            usageClient: KimiUsageClient(http: httpClient, environment: FakeEnvironment()),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func credentialsJSON(accessToken: String = "access-token", expiresAt: Double) -> String {
        """
        {"access_token":"\(accessToken)","refresh_token":"refresh-token","expires_at":\(Int(expiresAt)),\
        "expires_in":900,"scope":"kimi-code","token_type":"Bearer"}
        """
    }

    private func refreshResponse() -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":900,\
            "scope":"kimi-code","token_type":"Bearer"}
            """.utf8)
        )
    }

    private func usageResponse() -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {"user":{"membership":{"level":"LEVEL_INTERMEDIATE"}},\
            "usage":{"limit":"100","used":"41","remaining":"59","resetTime":"2026-07-31T07:54:26Z"},\
            "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},\
            "detail":{"limit":"100","used":"100","resetTime":"2026-07-24T17:54:26Z"}}]}
            """.utf8)
        )
    }
}

// MARK: - Doubles

/// Records the paths a locked critical section ran under, without creating real lock files.
private final class FakeFileLock: FileLocking, @unchecked Sendable {
    var lockedPaths: [String] = []

    func withExclusiveLock(at path: String, _ body: () throws -> Void) throws {
        lockedPaths.append(path)
        try body()
    }
}

private final class QueueHTTPClient: HTTPClient, @unchecked Sendable {
    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}
