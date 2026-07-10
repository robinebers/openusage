import XCTest
@testable import OpenUsage

final class CodexAuthStoreTests: XCTestCase {
    func testParsesHexEncodedAuthPayload() {
        let raw = #"{"tokens":{"access_token":"token"},"last_refresh":"2026-01-01T00:00:00.000Z"}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let auth = CodexAuthStore.parseAuth(hex)

        XCTAssertEqual(auth?.tokens?.accessToken, "token")
    }

    // MARK: needsRefresh (issue #516 — refresh by JWT exp, not a hardcoded 8-day age)

    func testValidFutureExpAccessTokenDoesNotNeedRefresh() {
        // A JWT whose `exp` is comfortably in the future must NOT trigger a proactive refresh, even
        // when `last_refresh` is old/missing — the old 8-day rule refreshed a still-valid token and
        // tripped refresh_token_reused.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: jwt(exp: now.addingTimeInterval(60 * 60))),
            lastRefresh: nil
        )

        XCTAssertFalse(store.needsRefresh(auth))
    }

    func testNearExpiryAccessTokenNeedsRefresh() {
        // Within the 5-minute window of `exp` ⇒ refresh now.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: jwt(exp: now.addingTimeInterval(60))),
            lastRefresh: nil
        )

        XCTAssertTrue(store.needsRefresh(auth))
    }

    func testNoExpClaimFallsBackToStaleLastRefresh() {
        // No decodable `exp` ⇒ fall back to the 8-day `last_refresh` rule; 9 days old ⇒ refresh.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let nineDaysAgo = OpenUsageISO8601.string(from: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: "token"),
            lastRefresh: nineDaysAgo
        )

        XCTAssertTrue(store.needsRefresh(auth))
    }

    func testNoExpClaimAndNoLastRefreshDoesNotForceRefresh() {
        // A brand-new login (no readable `exp`, no `last_refresh`) must NOT be forced to refresh — the
        // old code returned true here and refreshed immediately on first launch.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(tokens: CodexTokens(accessToken: "token"), lastRefresh: nil)

        XCTAssertFalse(store.needsRefresh(auth))
    }

    /// Builds a real JWT-shaped token: `base64url(header).base64url({"exp":<epoch>}).sig`.
    private func jwt(exp date: Date) -> String {
        func b64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"RS256","typ":"JWT"}"#)
        let payload = b64url(#"{"exp":\#(Int(date.timeIntervalSince1970))}"#)
        return "\(header).\(payload).sig"
    }

    func testUsesCodexHomeAuthPathBeforeDefaultPaths() {
        let files = FakeFiles([
            "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: files,
            keychain: FakeKeychain()
        )

        let candidates = store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.auth.tokens?.accessToken, "token")
    }
}
