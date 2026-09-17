import XCTest
@testable import OpenUsage

// Fixture values are invented — never real account data. Shape mirrors the
// server-rendered dev.meta.ai usage page described in docs/providers/muse.md.
private let museUsagePageFixture = """
<html><head><script>window.preloader = {"other":1};</script></head>
<body><script>SSR_BOOT={"llm":{"LLMDCUsageQuery":{"subscription_quota_usage":\
{"tier":"Muse Code Test Usage","as_of":1788000000,\
"window_weighted_used":"42.5","window_weighted_limit":"100.0","window_resets_at":1788100000,\
"weekly_weighted_used":"10","weekly_weighted_limit":"200","weekly_resets_at":1788600000},\
"available_models":[]}}}</script></body></html>
"""

final class MuseUsagePageTests: XCTestCase {
    func testClientSendsCookieAndAccept() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(museUsagePageFixture.utf8)))
        let client = MuseUsagePageClient(http: http)
        _ = try await client.fetchUsagePage(sessionCookie: "sess-value")
        XCTAssertEqual(http.requests.count, 1)
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.url, MuseUsagePageClient.usageURL)
        XCTAssertEqual(req.headers["Cookie"], "llm_sess=sess-value")
        XCTAssertTrue(req.headers["Accept"]?.contains("text/html") == true)
    }

    func testMapperParsesQuota() throws {
        let usage = try MuseUsagePageMapper.mapUsagePage(museUsagePageFixture)
        XCTAssertEqual(usage.tier, "Muse Code Test Usage")
        XCTAssertEqual(usage.windowUsedPercent ?? -1, 42.5, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsedPercent ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(usage.windowResetsAt, Date(timeIntervalSince1970: 1788100000))
        XCTAssertEqual(usage.weeklyResetsAt, Date(timeIntervalSince1970: 1788600000))
    }

    func testMapperMissingBlobIsUnauthorized() {
        XCTAssertThrowsError(try MuseUsagePageMapper.mapUsagePage("<html><body>login</body></html>")) { error in
            XCTAssertEqual(error as? MuseQuotaError, .unauthorized)
        }
    }

    func testMapperZeroLimitsAreInvalid() {
        let html = #"{"subscription_quota_usage":{"tier":"t","window_weighted_used":"0","window_weighted_limit":"0","window_resets_at":1,"weekly_weighted_used":"0","weekly_weighted_limit":"0","weekly_resets_at":1}}"#
        XCTAssertThrowsError(try MuseUsagePageMapper.mapUsagePage(html)) { error in
            XCTAssertEqual(error as? MuseQuotaError, .invalidResponse)
        }
    }

    func testExtractSkipsEscapedBraces() {
        // A preceding blob with escaped quotes/braces must not end the scan early.
        let html = #"{"other":"a\"}b","subscription_quota_usage":{"tier":"t","window_weighted_used":"1","window_weighted_limit":"2","window_resets_at":3,"weekly_weighted_used":"1","weekly_weighted_limit":"4","weekly_resets_at":5}}"#
        let quota = MuseUsagePageMapper.extractQuotaObject(html)
        XCTAssertEqual(quota?["tier"] as? String, "t")
    }

    func testDefaultBrowserPrefersHttps() {
        let output = """
        {
            LSHandlerRoleAll = "com.apple.safari";
            LSHandlerURLScheme = http;
            LSHandlerRoleAll = "com.google.chrome";
            LSHandlerURLScheme = https;
        }
        """
        XCTAssertEqual(MuseSessionCookieStore.parseDefaultBrowser(output), .chrome)
    }

    func testDefaultBrowserUnknownIsNil() {
        XCTAssertNil(MuseSessionCookieStore.parseDefaultBrowser("no handlers here"))
    }

    func testChromiumPathsCoverProfiles() {
        let paths = MuseSessionCookieStore.chromiumCookiePaths(.chrome)
        XCTAssertTrue(paths.contains { $0.hasSuffix("Google/Chrome/Default/Cookies") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Google/Chrome/Profile 1/Cookies") })
        XCTAssertTrue(MuseSessionCookieStore.chromiumCookiePaths(.firefox).isEmpty)
    }

    func testBinaryCookiesMalformedIsAbsent() {
        XCTAssertNil(MuseBinaryCookies.cookie(named: "llm_sess", domainHint: "meta.ai", in: Data("garbage".utf8)))
        XCTAssertFalse(MuseBinaryCookies.isWellFormed(Data("garbage".utf8)))
    }

    func testDecryptRejectsBadVersion() {
        XCTAssertThrowsError(try MuseCookieDecrypt.decryptChromiumCookie(hex: "deadbeef", password: "x")) { error in
            XCTAssertEqual(error as? MuseCookieError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try MuseCookieDecrypt.decryptChromiumCookie(hex: "zz", password: "x")) { error in
            XCTAssertEqual(error as? MuseCookieError, .unsupportedVersion)
        }
    }
}
