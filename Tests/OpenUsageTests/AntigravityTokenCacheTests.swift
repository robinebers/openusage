import XCTest
@testable import OpenUsage

final class AntigravityTokenCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testExtractTokenFromGoKeyringWrappedJSON() {
        let inner = """
        {"token":{"access_token":"ya29.test","refresh_token":"1//refresh","expiry":"2099-01-01T00:00:00Z","token_type":"Bearer"},"auth_method":"consumer"}
        """
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let token = AntigravityAuthStore.extractToken(fromKeychainRaw: wrapped)
        XCTAssertEqual(token?.accessToken, "ya29.test")
        XCTAssertEqual(token?.refreshToken, "1//refresh")
        XCTAssertEqual(token?.expiry, OpenUsageISO8601.date(from: "2099-01-01T00:00:00Z"))
    }

    func testExtractTokenFromRawJSONAndBearerAndPlain() {
        let plainJSON = #"{"access_token":"abc","refresh_token":"r"}"#
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: plainJSON)?.accessToken, "abc")
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: "Bearer xyz")?.accessToken, "xyz")
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: "rawtoken")?.accessToken, "rawtoken")
    }

    func testLoadKeychainTokenThroughStore() throws {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let store = AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles())
        let token = try store.loadKeychainToken()
        XCTAssertEqual(token?.accessToken, "ya29.kc")
        XCTAssertEqual(token?.refreshToken, "1//r")
    }

    func testCachedTokenLoadsOnlyForMatchingRefreshCredential() {
        let files = FakeFiles()
        let store = makeStore(files: files)
        let source = AntigravityKeychainToken(
            accessToken: "ya29.source",
            refreshToken: "matching-refresh-credential",
            expiry: nil
        )

        store.cacheToken(
            "ya29.cached",
            expiresIn: 7_200,
            sourceRefreshToken: "matching-refresh-credential"
        )

        XCTAssertEqual(store.loadCachedToken(matching: source), "ya29.cached")
        XCTAssertFalse(
            files.files[AntigravityAuthStore.cachePath]?.contains("matching-refresh-credential") == true,
            "the cache must store only a one-way credential fingerprint"
        )
    }

    func testMismatchedAndLegacyCachesAreDiscarded() {
        let currentSource = AntigravityKeychainToken(
            accessToken: "ya29.current",
            refreshToken: "current-refresh-credential",
            expiry: nil
        )
        let switchedFiles = FakeFiles()
        let switchedStore = makeStore(files: switchedFiles)
        switchedStore.cacheToken(
            "ya29.previous-account",
            expiresIn: 7_200,
            sourceRefreshToken: "previous-refresh-credential"
        )

        XCTAssertNil(switchedStore.loadCachedToken(matching: currentSource))
        XCTAssertNil(switchedFiles.files[AntigravityAuthStore.cachePath])

        let expiresAtMs = (now.timeIntervalSince1970 + 7_200) * 1_000
        let legacyFiles = FakeFiles([
            AntigravityAuthStore.cachePath: #"{"accessToken":"ya29.legacy","expiresAtMs":\#(expiresAtMs)}"#
        ])
        let legacyStore = makeStore(files: legacyFiles)

        XCTAssertNil(legacyStore.loadCachedToken(matching: currentSource))
        XCTAssertNil(legacyFiles.files[AntigravityAuthStore.cachePath])
    }

    func testCacheWithoutCurrentRefreshCredentialIsDiscarded() {
        let files = FakeFiles()
        let store = makeStore(files: files)
        store.cacheToken(
            "ya29.cached",
            expiresIn: 7_200,
            sourceRefreshToken: "previous-refresh-credential"
        )
        let sourceWithoutRefresh = AntigravityKeychainToken(
            accessToken: "ya29.current",
            refreshToken: nil,
            expiry: nil
        )

        XCTAssertNil(store.loadCachedToken(matching: sourceWithoutRefresh))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testMalformedCacheIsDiscardedForCurrentLogin() {
        let files = FakeFiles([AntigravityAuthStore.cachePath: "{ not-json"])
        let store = makeStore(files: files)
        let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)

        XCTAssertNil(store.loadCachedToken(matching: source))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testCacheWithEmptyAccessTokenIsDiscardedForCurrentLogin() {
        let files = FakeFiles()
        let store = makeStore(files: files)
        let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)
        store.cacheToken(" \n", expiresIn: 7_200, sourceRefreshToken: "refresh")

        XCTAssertNotNil(files.files[AntigravityAuthStore.cachePath])
        XCTAssertNil(store.loadCachedToken(matching: source))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    func testUnreadableCacheIsIgnoredForCurrentLogin() {
        let store = makeStore(files: UnreadableAntigravityCacheFiles())
        let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)

        XCTAssertNil(store.loadCachedToken(matching: source))
    }

    func testLoadCachedTokenAppliesRefreshBuffer() {
        let files = FakeFiles()
        let store = makeStore(files: files)
        let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)
        store.cacheToken("ya29.cached", expiresIn: 30, sourceRefreshToken: "refresh")

        // Within the 60s refresh buffer -> treated as expired (avoids a near-certain 401 + extra refresh).
        XCTAssertNil(store.loadCachedToken(matching: source))
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    private func makeStore(files: TextFileAccessing) -> AntigravityAuthStore {
        let fixedNow = now
        return AntigravityAuthStore(keychain: FakeKeychain(), files: files, now: { fixedNow })
    }
}

private struct UnreadableAntigravityCacheFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }

    func readText(_ path: String) throws -> String {
        throw UnreadableAntigravityCacheError.unreadable
    }

    func writeText(_ path: String, _ text: String) throws {}

    func remove(_ path: String) throws {}
}

private enum UnreadableAntigravityCacheError: Error {
    case unreadable
}
