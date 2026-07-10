import XCTest
@testable import OpenUsage

final class CredentialSystemClientIntegrityTests: XCTestCase {
    func testReadTextIfPresentReturnsNilOnlyForMissingFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.missing.\(UUID().uuidString)")
        XCTAssertNil(try LocalTextFileAccessor().readTextIfPresent(missing.path))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.directory.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try LocalTextFileAccessor().readTextIfPresent(directory.path))
    }

    func testSQLiteQueryDoesNotLaunchForMissingDatabase() throws {
        let runner = CredentialCountingProcessRunner()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.missing.\(UUID().uuidString).sqlite")

        XCTAssertNil(
            try SQLiteCLIAccessor(processRunner: runner)
                .queryValue(path: path.path, sql: "SELECT value FROM ItemTable LIMIT 1")
        )
        XCTAssertEqual(runner.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testSQLiteQueryOpensExistingDatabaseReadOnly() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.existing.\(UUID().uuidString).sqlite")
        try Data().write(to: database)
        defer { try? FileManager.default.removeItem(at: database) }
        let runner = CredentialCountingProcessRunner()

        XCTAssertNil(
            try SQLiteCLIAccessor(processRunner: runner)
                .queryValue(path: database.path, sql: "SELECT value FROM ItemTable LIMIT 1")
        )
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertTrue(runner.lastArguments.contains("-readonly"))
    }
}

@MainActor
final class AntigravityCredentialCacheIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCachedTokenLoadsOnlyForMatchingLogin() {
        let files = FakeFiles()
        let store = makeStore(files: files)
        store.cacheToken("current-access", expiresIn: 7_200, sourceRefreshToken: "current-refresh")
        let current = AntigravityKeychainToken(
            accessToken: nil,
            refreshToken: "current-refresh",
            expiry: nil
        )

        XCTAssertEqual(store.loadCachedToken(matching: current), "current-access")
        XCTAssertFalse(files.files[AntigravityAuthStore.cachePath]?.contains("current-refresh") == true)

        store.cacheToken("old-access", expiresIn: 7_200, sourceRefreshToken: "old-refresh")
        XCTAssertNil(store.loadCachedToken(matching: current))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testLegacyMalformedAndExpiredCachesAreDiscarded() {
        let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)
        let expiresAtMs = (now.timeIntervalSince1970 + 7_200) * 1_000
        for cache in [
            #"{"accessToken":"legacy","expiresAtMs":\#(expiresAtMs)}"#,
            "{ not-json"
        ] {
            let files = FakeFiles([AntigravityAuthStore.cachePath: cache])
            XCTAssertNil(makeStore(files: files).loadCachedToken(matching: source))
            XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
        }

        let files = FakeFiles()
        let store = makeStore(files: files)
        store.cacheToken("expired", expiresIn: 30, sourceRefreshToken: "refresh")
        XCTAssertNil(store.loadCachedToken(matching: source))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testLogoutRemovesCacheWithoutSendingIt() async {
        let files = FakeFiles()
        makeStore(files: files)
            .cacheToken("old-access", expiresIn: 7_200, sourceRefreshToken: "old-refresh")
        let http = RoutingHTTPClient { _ in
            XCTFail("a derived token must not be sent after logout")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(keychain: FakeKeychain(), files: files, http: http)

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testKeychainReadFailureRetainsButNeverUsesCache() async {
        let files = FakeFiles()
        makeStore(files: files)
            .cacheToken("old-access", expiresIn: 7_200, sourceRefreshToken: "old-refresh")
        let http = RoutingHTTPClient { _ in
            XCTFail("an unverified derived token must not leave the machine")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(keychain: FailingAntigravityKeychain(), files: files, http: http)

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNotNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testAccountSwitchNeverSendsPreviousCachedToken() async {
        let files = FakeFiles()
        makeStore(files: files)
            .cacheToken("old-access", expiresIn: 7_200, sourceRefreshToken: "old-refresh")
        let http = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)
                )
            }
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = makeProvider(
            keychain: FakeKeychain(keychainToken(access: "expired-access", refresh: "new-refresh")),
            files: files,
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        let authorizations = http.requests.compactMap { $0.headers["Authorization"] }
        XCTAssertTrue(authorizations.contains("Bearer new-access"))
        XCTAssertFalse(authorizations.contains("Bearer old-access"))
    }

    func testMatchingCacheAvoidsAnotherOAuthRefresh() async {
        let files = FakeFiles()
        makeStore(files: files)
            .cacheToken("cached-access", expiresIn: 7_200, sourceRefreshToken: "current-refresh")
        let http = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                XCTFail("a cache bound to the current login should avoid another OAuth refresh")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = makeProvider(
            keychain: FakeKeychain(keychainToken(access: "expired-access", refresh: "current-refresh")),
            files: files,
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(http.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        let authorizations = http.requests.compactMap { $0.headers["Authorization"] }
        XCTAssertEqual(Set(authorizations), ["Bearer cached-access"])
    }

    func testMalformedStructuredKeychainValueIsNotSentAsBearerToken() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("malformed structured credentials must not be sent")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(keychain: FakeKeychain("{broken-json"), files: FakeFiles(), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testBOMPrefixedMalformedStructuredKeychainValueIsNotSentAsBearerToken() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("BOM-prefixed malformed structured credentials must not be sent")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let malformed = "\u{FEFF} \n\t{broken-json"
        let provider = makeProvider(keychain: FakeKeychain(malformed), files: FakeFiles(), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func makeStore(files: TextFileAccessing) -> AntigravityAuthStore {
        let fixedNow = now
        return AntigravityAuthStore(keychain: FakeKeychain(), files: files, now: { fixedNow })
    }

    private func makeProvider(
        keychain: KeychainAccessing,
        files: TextFileAccessing,
        http: RoutingHTTPClient
    ) -> AntigravityProvider {
        let fixedNow = now
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: keychain, files: files, now: { fixedNow }),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: CredentialEmptyProcessRunner()),
            now: { fixedNow }
        )
    }

    private func keychainToken(access: String, refresh: String) -> String {
        let json = """
        {"token":{"access_token":"\(access)","refresh_token":"\(refresh)","expiry":"2000-01-01T00:00:00Z"}}
        """
        return "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
    }
}

private final class CredentialCountingProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastArguments: [String] = []

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        callCount += 1
        lastArguments = arguments
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct CredentialEmptyProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct FailingAntigravityKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? {
        throw FailingAntigravityKeychainError.unreadable
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

private enum FailingAntigravityKeychainError: Error {
    case unreadable
}
