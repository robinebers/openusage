import XCTest
@testable import OpenUsage

/// Auth-store config handling and the login controller's pure cookie-capture logic (no WebView —
/// the window itself is manual-validation-only, like every credential UI in the app).
final class QwenSessionCaptureTests: XCTestCase {
    private static let configPath = "~/.config/openusage/qwen.json"

    // MARK: - QwenAuthStore.session(fromConfigText:)

    func testJSONConfigWithCookiesAndRegion() {
        let text = """
        {"cookies":"login_qwencloud_ticket=abc; cna=xyz","region":"ap-southeast-1","source":"manual"}
        """
        let session = QwenAuthStore.session(fromConfigText: text)
        XCTAssertEqual(session?.cookies, "login_qwencloud_ticket=abc; cna=xyz")
        XCTAssertEqual(session?.region, "ap-southeast-1")
    }

    func testJSONConfigDefaultsRegion() {
        let session = QwenAuthStore.session(fromConfigText: "{\"cookies\":\"login_qwencloud_ticket=abc\"}")
        XCTAssertEqual(session?.region, "ap-southeast-1")
    }

    func testJSONConfigWithBlankRegionDefaults() {
        let session = QwenAuthStore.session(fromConfigText: """
        {"cookies":"login_qwencloud_ticket=abc","region":"  "}
        """)
        XCTAssertEqual(session?.region, "ap-southeast-1")
    }

    func testPlainTextCookieHeaderIsAccepted() {
        // A user who copies the cookie header straight from DevTools can paste it as the whole file.
        let session = QwenAuthStore.session(fromConfigText: "login_qwencloud_ticket=abc; cna=xyz\n")
        XCTAssertEqual(session?.cookies, "login_qwencloud_ticket=abc; cna=xyz")
        XCTAssertEqual(session?.region, "ap-southeast-1")
    }

    func testEmptyAndCookielessInputsAreRejected() {
        XCTAssertNil(QwenAuthStore.session(fromConfigText: ""))
        XCTAssertNil(QwenAuthStore.session(fromConfigText: "   \n"))
        XCTAssertNil(QwenAuthStore.session(fromConfigText: "{\"region\":\"ap-southeast-1\"}"))
        XCTAssertNil(QwenAuthStore.session(fromConfigText: "{\"cookies\":\"\"}"))
        // Broken/partial JSON is rejected rather than stored as a cookie string.
        XCTAssertNil(QwenAuthStore.session(fromConfigText: "login_qwencloud_ticket=x { broken"))
    }

    // MARK: - QwenUsageClient.paramsEnvelope

    func testParamsEnvelopeCarriesGatewayIdentity() {
        let envelope = QwenUsageClient.paramsEnvelope(apiName: QwenUsageClient.Endpoint.usage.apiName)
        // The cornerstone block is the console's site identity — a silent drift here breaks every
        // call, so pin the values, not just the presence of `params=`.
        XCTAssertTrue(envelope.contains("\"Api\":\"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage\""))
        XCTAssertTrue(envelope.contains("\"domain\":\"home.qwencloud.com\""))
        XCTAssertTrue(envelope.contains("\"consoleSite\":\"QWENCLOUD\""))
        XCTAssertTrue(envelope.contains("\"console\":\"ONE_CONSOLE\""))
        XCTAssertTrue(envelope.contains("\"xsp_lang\":\"en-US\""))
        XCTAssertTrue(envelope.contains("\"protocol\":\"V2\""))
        XCTAssertTrue(envelope.contains("\"productCode\":\"p_efm\""))
        XCTAssertTrue(envelope.contains("\"V\":\"1.0\""))
    }

    // MARK: - QwenAuthStore file round-trip

    func testSaveAndLoadRoundTrip() throws {
        let files = FakeFiles()
        let store = QwenAuthStore(files: files)
        XCTAssertNil(store.loadSession())
        try store.saveSession(cookies: "login_qwencloud_ticket=t0k3n", source: "webView")
        let session = store.loadSession()
        XCTAssertEqual(session?.cookies, "login_qwencloud_ticket=t0k3n")
        XCTAssertEqual(session?.region, "ap-southeast-1")
        // Save writes the documented JSON shape (so hand edits and the app agree).
        XCTAssertTrue(files.files[Self.configPath]?.contains("\"cookies\"") == true)
    }

    func testDeleteRemovesSessionAndMissingFileIsNoOp() throws {
        let files = FakeFiles()
        let store = QwenAuthStore(files: files)
        try store.deleteSession() // no file yet — must not throw
        try store.saveSession(cookies: "login_qwencloud_ticket=t0k3n", source: "manual")
        try store.deleteSession()
        XCTAssertNil(store.loadSession())
    }

    func testSaveRejectsBlankCookies() {
        let store = QwenAuthStore(files: FakeFiles())
        XCTAssertThrowsError(try store.saveSession(cookies: "  \n", source: "manual")) { error in
            XCTAssertEqual(error as? QwenAuthError, .saveFailed)
        }
    }

    // MARK: - QwenLoginController.cookieHeader(from:)

    private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/"
        ])!
    }

    func testCookieHeaderKeepsQwenCloudCookiesAndRequiresTicket() {
        let cookies = [
            cookie(name: "login_qwencloud_ticket", value: "t0k3n", domain: ".qwencloud.com"),
            cookie(name: "cna", value: "abc", domain: "home.qwencloud.com"),
            cookie(name: "unrelated", value: "zzz", domain: ".example.com")
        ]
        let header = QwenLoginController.cookieHeader(from: cookies)
        XCTAssertNotNil(header)
        XCTAssertTrue(header!.contains("login_qwencloud_ticket=t0k3n"))
        XCTAssertTrue(header!.contains("cna=abc"))
        XCTAssertFalse(header!.contains("unrelated"))
    }

    func testCookieHeaderWithoutTicketIsNil() {
        let cookies = [cookie(name: "cna", value: "abc", domain: ".qwencloud.com")]
        XCTAssertNil(QwenLoginController.cookieHeader(from: cookies))
    }

    func testCookieHeaderEmptySetIsNil() {
        XCTAssertNil(QwenLoginController.cookieHeader(from: []))
    }

    func testDomainMatching() {
        XCTAssertTrue(QwenLoginController.isQwenCloudDomain("qwencloud.com"))
        XCTAssertTrue(QwenLoginController.isQwenCloudDomain(".qwencloud.com"))
        XCTAssertTrue(QwenLoginController.isQwenCloudDomain("home.qwencloud.com"))
        XCTAssertTrue(QwenLoginController.isQwenCloudDomain("cs-data.qwencloud.com"))
        XCTAssertFalse(QwenLoginController.isQwenCloudDomain("example.com"))
        XCTAssertFalse(QwenLoginController.isQwenCloudDomain("notqwencloud.com"))
    }
}
