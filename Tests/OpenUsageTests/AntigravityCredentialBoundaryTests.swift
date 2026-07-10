import XCTest
@testable import OpenUsage

@MainActor
final class AntigravityCredentialBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingSourcesRemainAbsent() async {
        let provider = makeProvider(keychain: FakeKeychain(), files: FakeFiles())

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), AntigravityError.notSignedIn.localizedDescription)
    }

    func testUnreadableKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            keychain: AntigravityBoundaryKeychain(readFails: true),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), AntigravityError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedWrappedKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            keychain: FakeKeychain("go-keyring-base64:not-base64"),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), AntigravityError.invalidCredentialData.localizedDescription)
    }

    func testJSONKeychainWithoutTokensIsMalformedNotARawBearerToken() async {
        let provider = makeProvider(
            keychain: FakeKeychain(#"{"account":"present-but-tokenless"}"#),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), AntigravityError.invalidCredentialData.localizedDescription)
    }

    func testKeychainReadFailureNeverUsesCachedCredential() async {
        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let files = boundCache(sourceRefreshToken: "old-account-refresh")
        let provider = makeProvider(
            keychain: AntigravityBoundaryKeychain(readFails: true),
            files: files,
            http: routing
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), AntigravityError.credentialStoreUnreadable.localizedDescription)
        XCTAssertTrue(routing.requests.isEmpty, "an unverified cached token must never leave the machine")
        XCTAssertNotNil(files.files[AntigravityAuthStore.cachePath], "a transient Keychain error must not erase the cache")
    }

    func testMatchingCacheIsUsedForCurrentReadableLoginWithoutOAuthRefresh() async {
        let files = boundCache(
            sourceRefreshToken: "current-account-refresh",
            accessToken: "current-account-cached-access"
        )
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                XCTFail("a valid cache bound to the current login must avoid an OAuth refresh")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let currentLogin = keychainToken(
            accessToken: "expired-current-account-access",
            refreshToken: "current-account-refresh",
            expiry: "2000-01-01T00:00:00Z"
        )
        let provider = makeProvider(keychain: FakeKeychain(currentLogin), files: files, http: routing)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(routing.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        let cloudAuthorizations = routing.requests
            .filter { $0.url.host != "oauth2.googleapis.com" }
            .compactMap { $0.headers["Authorization"] }
        XCTAssertFalse(cloudAuthorizations.isEmpty)
        XCTAssertEqual(Set(cloudAuthorizations), ["Bearer current-account-cached-access"])
    }

    func testAccountSwitchRejectsOldCacheAndRefreshesCurrentLogin() async {
        let files = boundCache(sourceRefreshToken: "old-account-refresh", accessToken: "old-account-access")
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-account-access","expires_in":3600}"#.utf8)
                )
            }
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let currentLogin = keychainToken(
            accessToken: "expired-new-account-access",
            refreshToken: "newaccountrefresh",
            expiry: "2000-01-01T00:00:00Z"
        )
        let provider = makeProvider(keychain: FakeKeychain(currentLogin), files: files, http: routing)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        let oauthRequest = routing.requests.first { $0.url.host == "oauth2.googleapis.com" }
        XCTAssertTrue(String(decoding: oauthRequest?.body ?? Data(), as: UTF8.self).contains("newaccountrefresh"))
        let cloudAuthorizations = routing.requests
            .filter { $0.url.host != "oauth2.googleapis.com" }
            .compactMap { $0.headers["Authorization"] }
        XCTAssertTrue(cloudAuthorizations.contains("Bearer new-account-access"))
        XCTAssertFalse(cloudAuthorizations.contains("Bearer old-account-access"))
        let currentSource = try? provider.authStore.loadKeychainToken()
        XCTAssertEqual(
            currentSource.flatMap { provider.authStore.loadCachedToken(matching: $0) },
            "new-account-access",
            "the successful refresh should replace the discarded cache under the current login"
        )
    }

    func testLogoutDoesNotTreatBoundCacheAsCredential() async {
        let files = boundCache(sourceRefreshToken: "signed-out-account-refresh")
        let routing = RoutingHTTPClient { _ in
            XCTFail("a cached token must not be used after logout")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(keychain: FakeKeychain(), files: files, http: routing)

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), AntigravityError.notSignedIn.localizedDescription)
        XCTAssertTrue(routing.requests.isEmpty)
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath], "logout should remove OpenUsage's stale derived token")
    }

    private func makeProvider(
        keychain: KeychainAccessing,
        files: TextFileAccessing,
        http: HTTPClient = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    ) -> AntigravityProvider {
        let fixedNow = now
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: keychain, files: files, now: { fixedNow }),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: AntigravityNoProcessRunner()),
            now: { fixedNow }
        )
    }

    private func boundCache(
        sourceRefreshToken: String,
        accessToken: String = "cached-access-token",
        expiresIn: TimeInterval = 3_600
    ) -> FakeFiles {
        let files = FakeFiles()
        let fixedNow = now
        AntigravityAuthStore(keychain: FakeKeychain(), files: files, now: { fixedNow }).cacheToken(
            accessToken,
            expiresIn: expiresIn,
            sourceRefreshToken: sourceRefreshToken
        )
        return files
    }

    private func keychainToken(accessToken: String, refreshToken: String, expiry: String) -> String {
        let json = """
        {"token":{"access_token":"\(accessToken)","refresh_token":"\(refreshToken)","expiry":"\(expiry)"}}
        """
        return "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
        return text
    }
}

private struct AntigravityBoundaryKeychain: KeychainAccessing {
    var value: String?
    var readFails: Bool

    init(value: String? = nil, readFails: Bool = false) {
        self.value = value
        self.readFails = readFails
    }

    func readGenericPassword(service: String) throws -> String? {
        if readFails { throw AntigravityBoundaryTestError.unreadable }
        return value
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        if readFails { throw AntigravityBoundaryTestError.unreadable }
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

private struct AntigravityNoProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private enum AntigravityBoundaryTestError: Error {
    case unreadable
}
