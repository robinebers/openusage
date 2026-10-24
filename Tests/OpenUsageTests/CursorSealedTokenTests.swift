import XCTest
@testable import OpenUsage

final class CursorSealedTokenTests: XCTestCase {
    func testRoundTripsAJWT() throws {
        let token = makeCursorJWT(sub: "auth0|sealed-user")
        let sealed = try CursorSealedToken.seal(token: token, password: "test-password")

        XCTAssertTrue(CursorSealedToken.isSealed(sealed))
        XCTAssertEqual(CursorSealedToken.open(stored: sealed, password: "test-password"), token)
        XCTAssertNil(CursorSealedToken.open(stored: sealed, password: "other-password"))
        XCTAssertNil(CursorSealedToken.open(stored: "cursor-safe-storage:v1:not-base64", password: "test-password"))
    }

    func testOpensSealedEditorLoginAheadOfTheCLIKeychain() throws {
        let editor = makeCursorJWT(sub: "auth0|editor-user")
        let cli = makeCursorJWT(sub: "auth0|cli-user")
        let password = "test-password"
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: try CursorSealedToken.seal(token: editor, password: password),
                CursorAuthStore.refreshTokenKey: try CursorSealedToken.seal(
                    token: makeCursorJWT(sub: "auth0|editor-refresh"),
                    password: password
                ),
                CursorAuthStore.membershipTypeKey: "ultra"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: cli,
                CursorAuthStore.keychainRefreshTokenService: "cli-refresh"
            ]),
            safeStorageKey: StaticSafeStorageKey(password: password)
        )

        let state = store.loadAuthState()

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, editor)
        XCTAssertEqual(state?.membershipType, "ultra")
        XCTAssertEqual(CursorAuthStore.tokenSubject(state?.refreshToken), "auth0|editor-refresh")
        XCTAssertFalse(store.needsRefresh(state?.accessToken))
    }

    func testSealedLoginWithoutAKeyFallsBackToTheCLILogin() throws {
        let cli = makeCursorJWT(sub: "auth0|cli-user")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: try CursorSealedToken.seal(
                    token: makeCursorJWT(),
                    password: "editor-password"
                ),
                CursorAuthStore.membershipTypeKey: "ultra"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: cli,
                CursorAuthStore.keychainRefreshTokenService: "cli-refresh"
            ]),
            safeStorageKey: StaticSafeStorageKey(password: nil)
        )

        let state = store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, cli)
        XCTAssertNil(state?.membershipType)
    }

    func testPersistsARotatedEditorTokenStillSealed() throws {
        let password = "test-password"
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: try CursorSealedToken.seal(token: makeCursorJWT(), password: password)
        ])
        let store = CursorAuthStore(
            sqlite: sqlite,
            keychain: FakeKeychain(),
            safeStorageKey: StaticSafeStorageKey(password: password)
        )
        let rotated = makeCursorJWT(sub: "auth0|rotated")

        try store.saveAccessToken(rotated, source: .sqlite)

        let written = try XCTUnwrap(sqlite.writtenValues[CursorAuthStore.accessTokenKey])
        XCTAssertTrue(CursorSealedToken.isSealed(written))
        XCTAssertEqual(CursorSealedToken.open(stored: written, password: password), rotated)
        XCTAssertFalse(written.contains(rotated))
    }

    func testDoesNotReplaceASealedEditorTokenWithPlaintext() throws {
        let sealed = try CursorSealedToken.seal(token: makeCursorJWT(), password: "editor-password")
        let sqlite = KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: sealed])
        let store = CursorAuthStore(
            sqlite: sqlite,
            keychain: FakeKeychain(),
            safeStorageKey: StaticSafeStorageKey(password: nil)
        )

        XCTAssertThrowsError(try store.saveAccessToken("plaintext-jwt", source: .sqlite))
        XCTAssertNil(sqlite.writtenValues[CursorAuthStore.accessTokenKey])
    }
}

private struct StaticSafeStorageKey: CursorSafeStorageKeyReading {
    var password: String?

    func readPassword() throws -> String? {
        password
    }
}
