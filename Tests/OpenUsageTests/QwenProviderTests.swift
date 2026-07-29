import XCTest
@testable import OpenUsage

/// Provider-level tests: a real `QwenProvider` wired to `FakeFiles` (the session config) and a
/// `RoutingHTTPClient` (canned info.json / api.json responses), with an injected clock. The canned
/// bodies are the same live captures as `QwenUsageMapperTests`.
@MainActor
final class QwenProviderTests: XCTestCase {
    private nonisolated static let configPath = "~/.config/openusage/qwen.json"
    private nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_785_350_000)

    private nonisolated static let configJSON = """
    {"cookies":"login_qwencloud_ticket=abc123; cna=xyz","region":"ap-southeast-1","source":"manual"}
    """

    /// Routes by URL the way the real endpoints differ: info.json by path, api.json calls by the
    /// percent-encoded endpoint suffix in the query.
    private func makeClient(
        info: (status: Int, body: String)? = (200, QwenUsageMapperTests.infoBody),
        usage: (status: Int, body: String)? = (200, QwenUsageMapperTests.usageBody),
        subscription: (status: Int, body: String)? = (200, QwenUsageMapperTests.subscriptionBody),
        quotaConfig: (status: Int, body: String)? = (200, QwenUsageMapperTests.quotaConfigBody)
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            let url = request.url.absoluteString
            func respond(_ canned: (status: Int, body: String)?) -> HTTPResponse {
                guard let canned else { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
                return HTTPResponse(statusCode: canned.status, headers: [:], body: Data(canned.body.utf8))
            }
            if url.contains("tool/user/info.json") { return respond(info) }
            if url.contains("%2Fusage") { return respond(usage) }
            if url.contains("%2Fsubscription") { return respond(subscription) }
            if url.contains("%2Fquota-config") { return respond(quotaConfig) }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func makeProvider(
        config: String? = configJSON,
        client: RoutingHTTPClient
    ) -> QwenProvider {
        var files: [String: String] = [:]
        if let config { files[Self.configPath] = config }
        return QwenProvider(
            authStore: QwenAuthStore(files: FakeFiles(files)),
            usageClient: QwenUsageClient(http: client),
            now: { Self.fixedNow }
        )
    }

    // MARK: - Happy path

    func testHappyPathMapsMetersPlanAndRenewalWarning() async throws {
        let provider = makeProvider(client: makeClient())
        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.providerID, "qwen")
        XCTAssertEqual(snapshot.refreshedAt, Self.fixedNow)
        XCTAssertEqual(snapshot.plan, "Standard · 3,000 / 5h · 10,000 / wk")
        XCTAssertEqual(snapshot.warning, "Auto-renew is off — plan ends in 22 days.")

        XCTAssertEqual(snapshot.lines.count, 2)
        guard case .progress(let label, let used, _, _, _, _, _)? = snapshot.line(label: "5-Hour") else {
            return XCTFail("expected the 5-Hour meter")
        }
        XCTAssertEqual(label, "5-Hour")
        XCTAssertEqual(used, 0.10967993005003332 * 100, accuracy: 0.0001)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testHappyPathSendsCookiesAndFormFields() async throws {
        let client = makeClient()
        _ = await makeProvider(client: client).refresh()

        // Every request carries the captured cookies.
        XCTAssertFalse(client.requests.isEmpty)
        for request in client.requests {
            XCTAssertEqual(request.headers["Cookie"], "login_qwencloud_ticket=abc123; cna=xyz")
        }

        // The usage call is a form POST with the gateway fields and the live sec_token.
        let usageRequest = try client.requests.first {
            $0.url.absoluteString.contains("%2Fusage")
        }.unwrap()
        XCTAssertEqual(usageRequest.method, "POST")
        let form = String(decoding: usageRequest.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("product=sfm_bailian"))
        XCTAssertTrue(form.contains("action=IntlBroadScopeAspnGateway"))
        XCTAssertTrue(form.contains("sec_token=NYOOSBQvO9PGTxFmHt0pT1"))
        XCTAssertTrue(form.contains("region=ap-southeast-1"))
        XCTAssertTrue(form.contains("params="))
        XCTAssertEqual(usageRequest.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(usageRequest.headers["Origin"], "https://home.qwencloud.com")
    }

    // MARK: - Credential states

    func testMissingConfigReportsNotLoggedIn() async {
        let provider = makeProvider(config: nil, client: makeClient())
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testHasLocalCredentialsMirrorsConfigPresence() async {
        let withConfig = makeProvider(client: makeClient())
        let withoutConfig = makeProvider(config: nil, client: makeClient())
        let has = await withConfig.hasLocalCredentials()
        let hasNot = await withoutConfig.hasLocalCredentials()
        XCTAssertTrue(has)
        XCTAssertFalse(hasNot)
    }

    // MARK: - Session expiry

    func testInfoLoginFailureReportsAuthExpired() async {
        let deadSession = """
        {"code":"200","data":{"secToken":null},"successResponse":false}
        """
        let provider = makeProvider(client: makeClient(info: (200, deadSession)))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testInfoWithoutSecTokenOrFailureMarkerReportsDecoding() async {
        // A 2xx body that is neither a login failure nor carries a token is malformed — a decoding
        // error, not an auth expiry (the two surface differently to the user).
        let oddBody = """
        {"code":"200","data":{"somethingElse":true},"successResponse":true}
        """
        let provider = makeProvider(client: makeClient(info: (200, oddBody)))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testInfo401ReportsAuthExpired() async {
        let provider = makeProvider(client: makeClient(info: (401, "{}")))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testInfo403ReportsAuthExpired() async {
        let provider = makeProvider(client: makeClient(info: (403, "{}")))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testUsageConsoleNeedLoginReportsAuthExpired() async {
        let expired = """
        {"code":"200","data":{"DataV2":{"data":{"code":"ConsoleNeedLogin","data":{}}},"errorCode":""},\
        "successResponse":true}
        """
        let provider = makeProvider(client: makeClient(usage: (200, expired)))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    // MARK: - Failures stay loud

    func testMalformedUsageReportsDecodingInsteadOfZeroMeters() async {
        let provider = makeProvider(client: makeClient(usage: (200, """
        {"code":"200","data":{"DataV2":{"data":{"code":"SUCCESS","data":{"unexpected":true}}}}}}
        """)))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .decoding)
        // The error snapshot is a single error badge — never blank meters that read as "0% used".
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertTrue(snapshot.lines[0].isError)
    }

    func testUsage500ReportsHttp5xx() async {
        let provider = makeProvider(client: makeClient(usage: (500, "boom")))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testUsage429ReportsRateLimited() async {
        let provider = makeProvider(client: makeClient(usage: (429, "slow down")))
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
    }

    func testUsageTransportErrorReportsNetwork() async {
        let client = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("%2Fusage") { throw URLError(.notConnectedToInternet) }
            let body = url.contains("tool/user/info.json")
                ? QwenUsageMapperTests.infoBody
                : QwenUsageMapperTests.subscriptionBody
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let snapshot = await makeProvider(client: client).refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    // MARK: - Best-effort decoration

    func testSubscriptionFailureStillMetersWithoutPlan() async {
        let provider = makeProvider(client: makeClient(subscription: (500, "x")))
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.count, 2)
    }

    func testQuotaFailureKeepsBareTierPlan() async {
        let provider = makeProvider(client: makeClient(quotaConfig: (500, "x")))
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Standard")
    }

    func testAutoRenewOnMeansNoWarning() async {
        let sub = """
        {"code":"200","data":{"DataV2":{"data":{"code":"SUCCESS","data":{"specCode":"pro",\
        "remainingDays":200,"autoRenewFlag":true,"status":"VALID"}}}},"successResponse":true}
        """
        let provider = makeProvider(client: makeClient(subscription: (200, sub), quotaConfig: (500, "x")))
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.plan, "Pro")
    }

    // MARK: - SessionManaging

    func testSessionManagingSignOutClearsSession() async throws {
        let files = FakeFiles([Self.configPath: Self.configJSON])
        let provider = QwenProvider(
            authStore: QwenAuthStore(files: files),
            usageClient: QwenUsageClient(http: makeClient())
        )
        let managing: any SessionManaging = provider
        XCTAssertTrue(managing.hasSession)
        try managing.signOut()
        XCTAssertFalse(managing.hasSession)
    }
}

private extension Optional {
    /// Test-only unwrap with a decent failure message.
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        switch self {
        case .some(let value): return value
        case .none:
            XCTFail("expected a value", file: file, line: line)
            throw QwenProviderTestError.unwrappedNil
        }
    }
}

private enum QwenProviderTestError: Error { case unwrappedNil }
