import XCTest
@testable import OpenUsage

/// Cursor's access token is a 60-day JWT that is also its refresh token. The login poll returns the
/// same JWT for both. `/oauth/token` answers with a new `access_token` and no `refresh_token`.
/// These shapes come from the live API on 2026-10-23. The tokens here are fake.
@MainActor
final class CursorTokenRefreshTests: XCTestCase {
    nonisolated private static let expiry = Date(timeIntervalSince1970: 4_000_000_000)
    nonisolated private static let newExpiry = expiry.addingTimeInterval(60 * 86_400)
    nonisolated private static let oldToken = fakeJWT(exp: expiry, user: "old")
    nonisolated private static let newToken = fakeJWT(exp: newExpiry, user: "new")

    nonisolated private static let usageBody = #"""
    {"billingCycleEnd":"1764547200000","billingCycleStart":"1761955200000","enabled":true,
     "planUsage":{"limit":2000,"remaining":1500,"totalPercentUsed":25}}
    """#

    nonisolated private static func fakeJWT(exp: Date, user: String) -> String {
        let payload = #"{"sub":"auth0|user_\#(user)","exp":\#(Int(exp.timeIntervalSince1970)),"type":"session"}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).fake-signature"
    }

    nonisolated private static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }

    nonisolated private static let refreshed = json(#"{"access_token":"\#(newToken)","id_token":"fake","shouldLogout":false}"#)

    private struct Harness {
        let runtime: AccountProviderRuntime
        let vault: InMemoryCredentialVault
        let http: RoutingHTTPClient
        let account: Account

        var stored: OAuthTokens? {
            guard case .oauth(let tokens)? = try? vault.load(account.id) else { return nil }
            return tokens
        }

        var refreshRequests: [HTTPRequest] { http.requests.filter { $0.url == CursorUsageClient.refreshURL } }

        var usageTokens: [String?] {
            http.requests.filter { $0.url == CursorUsageClient.usageURL }
                .map { $0.headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "") }
        }
    }

    private func harness(stored: OAuthTokens, now: Date, refresh: HTTPResponse, acceptedTokens: Set<String>) throws -> Harness {
        let account = Account(kind: .cursor, label: "Cursor Account")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(stored), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.refreshURL: return refresh
            case CursorUsageClient.usageURL:
                let token = request.headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
                return acceptedTokens.contains(token) ? Self.json(Self.usageBody) : Self.json("{}", status: 401)
            case CursorUsageClient.planURL: return Self.json(#"{"planInfo":{"planName":"Pro"}}"#)
            default: return Self.json("{}", status: 404)
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { now })
        return Harness(runtime: runtime, vault: vault, http: http, account: account)
    }

    private func assertRefreshedAndSaved(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        let request = try XCTUnwrap(harness.refreshRequests.first, "no refresh request", file: file, line: line)
        let body = try XCTUnwrap(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(body["grant_type"], "refresh_token", file: file, line: line)
        XCTAssertEqual(body["client_id"], CursorUsageClient.clientID, file: file, line: line)
        XCTAssertEqual(body["refresh_token"], Self.oldToken, file: file, line: line)
        XCTAssertEqual(
            harness.stored,
            OAuthTokens(accessToken: Self.newToken, refreshToken: Self.newToken, expiresAt: Self.newExpiry),
            file: file, line: line
        )
    }

    func testLoginSavesTheAccessTokensExpiry() async throws {
        let http = RoutingHTTPClient { _ in
            Self.json(#"{"accessToken":"\#(Self.oldToken)","refreshToken":"\#(Self.oldToken)"}"#)
        }

        let result = try await CursorLogin(http: http).login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })

        guard case .oauth(let tokens) = result.credential else { return XCTFail("Expected OAuth tokens") }
        XCTAssertEqual(tokens.expiresAt, Self.expiry)
    }

    func testCredentialWithoutExpiryGetsOneFromItsJWT() async throws {
        let harness = try harness(
            stored: OAuthTokens(accessToken: Self.oldToken, refreshToken: Self.oldToken),
            now: Self.expiry.addingTimeInterval(-30 * 86_400),
            refresh: Self.refreshed,
            acceptedTokens: [Self.oldToken]
        )

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(harness.stored?.expiresAt, Self.expiry)
        XCTAssertEqual(harness.stored?.accessToken, Self.oldToken)
        XCTAssertTrue(harness.refreshRequests.isEmpty)
    }

    func testTokenNearExpiryIsRefreshedFirstAndSaved() async throws {
        let harness = try harness(
            stored: OAuthTokens(accessToken: Self.oldToken, refreshToken: Self.oldToken, expiresAt: Self.expiry),
            now: Self.expiry.addingTimeInterval(-86_400),
            refresh: Self.refreshed,
            acceptedTokens: [Self.newToken]
        )

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(harness.usageTokens, [Self.newToken])
        try assertRefreshedAndSaved(harness)
    }

    func testRejectedTokenIsRefreshedOnceAndRetried() async throws {
        let harness = try harness(
            stored: OAuthTokens(accessToken: Self.oldToken, refreshToken: Self.oldToken, expiresAt: Self.expiry),
            now: Self.expiry.addingTimeInterval(-30 * 86_400),
            refresh: Self.refreshed,
            acceptedTokens: [Self.newToken]
        )

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(harness.usageTokens, [Self.oldToken, Self.newToken])
        try assertRefreshedAndSaved(harness)
    }

    func testFailedRefreshOfExpiredTokenReadsAsExpiredSignIn() async throws {
        let harness = try harness(
            stored: OAuthTokens(accessToken: Self.oldToken, refreshToken: Self.oldToken),
            now: Self.expiry.addingTimeInterval(3_600),
            refresh: Self.json(#"{"access_token":"","id_token":"","shouldLogout":true}"#),
            acceptedTokens: []
        )

        let snapshot = await harness.runtime.refresh()

        XCTAssertEqual(harness.refreshRequests.count, 1)
        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, "Cursor sign-in expired. Remove the account and add it again.")
        XCTAssertEqual(harness.stored?.accessToken, Self.oldToken)
    }

    func testFailedEarlyRefreshKeepsTheStillValidToken() async throws {
        let harness = try harness(
            stored: OAuthTokens(accessToken: Self.oldToken, refreshToken: Self.oldToken, expiresAt: Self.expiry),
            now: Self.expiry.addingTimeInterval(-86_400),
            refresh: Self.json("{}", status: 503),
            acceptedTokens: [Self.oldToken]
        )

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(harness.refreshRequests.count, 1)
        XCTAssertEqual(harness.usageTokens, [Self.oldToken])
        XCTAssertEqual(harness.stored?.accessToken, Self.oldToken)
    }
}
