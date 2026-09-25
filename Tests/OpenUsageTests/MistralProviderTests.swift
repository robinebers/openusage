import CommonCrypto
import CryptoKit
import XCTest
@testable import OpenUsage

// MARK: - Fixtures

/// The subscription page's flight stream carries the two allowance objects. Chunk shape mirrors
/// Next.js: `self.__next_f.push([1, "…"])` with escaped quotes inside the JSON.
private func subscriptionPage(apiJSON: String, vibeJSON: String) -> String {
    let chunk = #"{"budget":{"api_budget":"# + apiJSON + #","vibe_budget":"# + vibeJSON + #"}}"#
    let escaped = chunk
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "<script>self.__next_f.push([1, \"" + escaped + "\"])</script>"
}

private let apiBudgetJSON = #"{"usage_percentage":42.5,"initial_budget":25.5,"currency":"EUR","reset_at":"2026-08-01T00:00:00Z"}"#
private let vibeBudgetJSON = #"{"usage_percentage":10,"initial_budget":255,"currency":"EUR","reset_at":"2026-08-01T00:00:00Z"}"#
private let vibeTRPCJSON = #"[{"result":{"data":{"json":{"usage_percentage":73.2,"reset_at":"2026-08-01T00:00:00Z","payg_enabled":false}}}}]"#

// MARK: - MistralAuthStoreTests

final class MistralAuthStoreTests: XCTestCase {
    func testParsesSavedHeaderWithSessionAndCSRF() throws {
        let auth = try XCTUnwrap(MistralAuthStore.parseCookieHeader(
            "Cookie: ory_session_abc=def; other=ignored; csrftoken=tok123"
        ))
        XCTAssertEqual(auth.cookieHeader, "ory_session_abc=def; csrftoken=tok123")
        XCTAssertEqual(auth.csrfToken, "tok123")
    }

    func testRejectsHeaderWithoutSessionCookie() {
        XCTAssertNil(MistralAuthStore.parseCookieHeader("csrftoken=tok; other=x"))
        XCTAssertNil(MistralAuthStore.parseCookieHeader(""))
    }

    func testSaveLoadAndDeleteRoundTrip() throws {
        let files = FakeFiles()
        let store = MistralAuthStore(
            files: files,
            sqlite: KeyValueSQLite(),
            keychain: FakeKeychain(),
            directoryLister: { _ in [] }
        )
        XCTAssertFalse(store.hasSavedHeader())
        try store.saveCookieHeader("  ory_session_abc=def; csrftoken=tok  ")
        XCTAssertTrue(store.hasSavedHeader())
        let auth = try XCTUnwrap(store.loadSavedHeader())
        XCTAssertEqual(auth.cookieHeader, "ory_session_abc=def; csrftoken=tok")
        try store.deleteSavedHeader()
        XCTAssertNil(try store.loadSavedHeader())
        XCTAssertFalse(store.hasSavedHeader())
    }

    func testSaveRejectsHeaderWithoutSession() {
        let store = MistralAuthStore(
            files: FakeFiles(),
            sqlite: KeyValueSQLite(),
            keychain: FakeKeychain(),
            directoryLister: { _ in [] }
        )
        XCTAssertThrowsError(try store.saveCookieHeader("csrftoken=tok")) { error in
            XCTAssertEqual(error as? MistralAuthError, .invalidCookieHeader)
        }
    }

    func testLoadSavedHeaderThrowsOnMalformedSavedFile() throws {
        let files = FakeFiles([MistralAuthStore.savedHeaderPath: #"{"cookieHeader":"no session here"}"#])
        let store = MistralAuthStore(
            files: files,
            sqlite: KeyValueSQLite(),
            keychain: FakeKeychain(),
            directoryLister: { _ in [] }
        )
        XCTAssertThrowsError(try store.loadSavedHeader()) { error in
            XCTAssertEqual(error as? MistralAuthError, .invalidCookieHeader)
        }
    }

    func testSavedFileAcceptsJSONAndPlainHeaderShapes() {
        let json = #"{"cookieHeader":"ory_session_abc=def; csrftoken=tok"}"#
        XCTAssertEqual(
            MistralAuthStore.savedHeaderText(fromFileContent: json),
            "ory_session_abc=def; csrftoken=tok"
        )
        XCTAssertEqual(
            MistralAuthStore.savedHeaderText(fromFileContent: "  ory_session_abc=def  "),
            "ory_session_abc=def"
        )
        XCTAssertNil(MistralAuthStore.savedHeaderText(fromFileContent: "{broken"))
    }

    func testFirefoxRowsDecodeToSessionAndCSRF() {
        let rows = [
            "plain:ory_session_abc=def",
            "plain:csrftoken=tok",
            "plain:ory_session_abc=stale-duplicate-ignored",
            "plain:other=x"
        ]
        let auth = MistralAuthStore.auth(fromEncodedRows: rows)
        XCTAssertEqual(auth?.cookieHeader, "ory_session_abc=def; csrftoken=tok")
        XCTAssertEqual(auth?.csrfToken, "tok")
    }

    func testChromiumDecryptsV10Value() throws {
        // Round-trip the documented envelope: AES-128-CBC, space-filled IV, PKCS7.
        let key = try XCTUnwrap(MistralAuthStore.deriveKey(password: "peanuts"))
        let plaintext = Data("ory-value".utf8)
        let sealed = sealedChromiumValue(plaintext, key: key)
        let decrypted = try XCTUnwrap(MistralAuthStore.decryptChromiumValue(sealed, key: key))
        XCTAssertEqual(decrypted, plaintext)
    }

    private func sealedChromiumValue(_ plaintext: Data, key: Data) -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            output.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return Data("v10".utf8) + output.prefix(outputLength)
    }
}

// MARK: - MistralUsageMapperTests

final class MistralUsageMapperTests: XCTestCase {
    func testMapsBothAllowancesFromSubscriptionPage() throws {
        let html = subscriptionPage(apiJSON: apiBudgetJSON, vibeJSON: vibeBudgetJSON)
        let lines = MistralUsageMapper.map(subscriptionHTML: html, vibeBody: nil)
        let api = try XCTUnwrap(progress(lines, "API"))
        XCTAssertEqual(api.used, 42.5, accuracy: 0.001)
        XCTAssertEqual(api.limit, 100)
        XCTAssertEqual(api.format, .percent)
        XCTAssertEqual(api.periodDurationMs, MistralUsageMapper.monthlyPeriodMs)
        XCTAssertNotNil(api.resetsAt)
        let vibe = try XCTUnwrap(progress(lines, "Vibe"))
        XCTAssertEqual(vibe.used, 10, accuracy: 0.001)
        XCTAssertEqual(vibe.limit, 100)
    }

    func testVibeTRPCFallbackWhenPageHasNoVibeBudget() throws {
        let html = subscriptionPage(apiJSON: apiBudgetJSON, vibeJSON: "null")
        let lines = MistralUsageMapper.map(subscriptionHTML: html, vibeBody: Data(vibeTRPCJSON.utf8))
        let api = try XCTUnwrap(progress(lines, "API"))
        XCTAssertEqual(api.used, 42.5, accuracy: 0.001)
        let vibe = try XCTUnwrap(progress(lines, "Vibe"))
        XCTAssertEqual(vibe.used, 73.2, accuracy: 0.001)
        XCTAssertNotNil(vibe.resetsAt)
    }

    func testAmbiguousBudgetStreamIsRejected() {
        // Two different api_budget objects: neither is taken (no way to tell which is this account's).
        let doubled = subscriptionPage(apiJSON: apiBudgetJSON, vibeJSON: vibeBudgetJSON)
            + "self.__next_f.push([1, \"{\\\"budget\\\":{\\\"api_budget\\\":{\\\"usage_percentage\\\":7}}}\"])"
        let (api, _) = MistralUsageMapper.allowancesFromSubscriptionPage(doubled)
        XCTAssertNil(api)
    }

    func testNoAllowancesAnywhereReadsNoUsageData() {
        let lines = MistralUsageMapper.map(subscriptionHTML: "<html>no data</html>", vibeBody: nil)
        XCTAssertEqual(lines, [.noUsageData])
        let lines2 = MistralUsageMapper.map(subscriptionHTML: nil, vibeBody: nil)
        XCTAssertEqual(lines2, [.noUsageData])
    }

    func testClampsAboveRangePercentage() {
        let html = subscriptionPage(
            apiJSON: #"{"usage_percentage":150,"initial_budget":10,"currency":"EUR"}"#,
            vibeJSON: "null"
        )
        let lines = MistralUsageMapper.map(subscriptionHTML: html, vibeBody: nil)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "API")).used, 100, accuracy: 0.001)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }
}

// MARK: - MistralProviderTests

@MainActor
final class MistralProviderTests: XCTestCase {
    func testRefreshMapsBothAllowances() async throws {
        let provider = MistralProvider(
            authStore: makeAuthStore(header: "ory_session_abc=def; csrftoken=tok"),
            usageClient: MistralUsageClient(http: RoutingHTTPClient { request in
                if request.url == MistralUsageClient.subscriptionURL {
                    return htmlResponse(subscriptionPage(apiJSON: apiBudgetJSON, vibeJSON: vibeBudgetJSON))
                }
                return mistralJSONResponse(vibeTRPCJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "API"))
        XCTAssertNotNil(snapshot.line(label: "Vibe"))
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
    }

    func testRefreshSurvivesSubscriptionFailureViaVibeFallback() async throws {
        let provider = MistralProvider(
            authStore: makeAuthStore(header: "ory_session_abc=def; csrftoken=tok"),
            usageClient: MistralUsageClient(http: RoutingHTTPClient { request in
                if request.url == MistralUsageClient.subscriptionURL {
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                return mistralJSONResponse(vibeTRPCJSON)
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.line(label: "API"))
        XCTAssertNotNil(snapshot.line(label: "Vibe"))
    }

    func testRefreshWithoutSessionReportsNotSignedIn() async {
        let provider = MistralProvider(
            authStore: MistralAuthStore(
                files: FakeFiles(),
                sqlite: KeyValueSQLite(),
                keychain: FakeKeychain(),
                directoryLister: { _ in [] }
            ),
            usageClient: MistralUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a session")
                return mistralJSONResponse("{}")
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, "Error")
    }

    func testRefreshClassifiesExpiredSession() async {
        for status in [301, 302, 401, 403] {
            let provider = MistralProvider(
                authStore: makeAuthStore(header: "ory_session_abc=def"),
                usageClient: MistralUsageClient(http: RoutingHTTPClient { _ in
                    HTTPResponse(statusCode: status, headers: [:], body: Data())
                })
            )
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, .authExpired, "status \(status)")
        }
    }

    func testProviderIdentity() {
        let provider = MistralProvider()
        XCTAssertEqual(provider.provider.id, "mistral")
        XCTAssertEqual(provider.provider.displayName, "Mistral")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["mistral.api", "mistral.vibe"])
    }

    private func makeAuthStore(header: String) -> MistralAuthStore {
        let store = MistralAuthStore(
            files: FakeFiles(),
            sqlite: KeyValueSQLite(),
            keychain: FakeKeychain(),
            directoryLister: { _ in [] }
        )
        try? store.saveCookieHeader(header)
        return store
    }
}

private func mistralJSONResponse(_ jsonString: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(jsonString.utf8))
}

private func htmlResponse(_ html: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8))
}
