import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class OAuthRefreshPersistenceTests: XCTestCase {
    func testClaudeRefreshPersistsRotatedCredentialToVault() async throws {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        try vault.save(
            .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)),
            for: account.id
        )
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        _ = await runtime.refresh()

        guard case .oauth(let saved)? = try vault.load(account.id) else {
            return XCTFail("Expected refreshed OAuth credential in the vault")
        }
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "rotated-refresh")
        XCTAssertNotNil(saved.expiresAt)
    }

    func testAntigravityRefreshPersistsTheNewAccessTokenAndUsesIt() async throws {
        let account = Account(kind: .antigravity, label: "Google")
        let vault = InMemoryCredentialVault()
        try vault.save(
            .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "google-refresh", expiresAt: .distantPast)),
            for: account.id
        )
        let http = RoutingHTTPClient { request in
            switch request.url.absoluteString {
            case "https://oauth2.googleapis.com/token":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            case "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary":
                let body = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = try await runtime.refresh().get()

        let tokenRequest = try XCTUnwrap(http.requests.first { $0.url.host() == "oauth2.googleapis.com" })
        XCTAssertEqual(String(decoding: tokenRequest.body ?? Data(), as: UTF8.self),
                       "client_id=\(AntigravityLogin.clientID.urlFormEncoded)&client_secret=\(AntigravityLogin.clientSecret.urlFormEncoded)"
                       + "&refresh_token=google-refresh&grant_type=refresh_token")
        let quotaRequests = http.requests.filter { $0.url.path.hasSuffix("retrieveUserQuotaSummary") }
        XCTAssertFalse(quotaRequests.isEmpty)
        XCTAssertTrue(quotaRequests.allSatisfy { $0.headers["Authorization"] == "Bearer new-access" }, "\(quotaRequests)")
        guard case .oauth(let saved)? = try vault.load(account.id) else {
            return XCTFail("Expected the refreshed OAuth credential in the vault")
        }
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "google-refresh")
        XCTAssertEqual(try XCTUnwrap(saved.expiresAt).timeIntervalSinceNow, 3600, accuracy: 5, "the provider's own expiry; the refresh margin applies when it is read")
    }

    func testAntigravityRefusedRefreshTokenReadsAsExpiredSignIn() async throws {
        let account = Account(kind: .antigravity, label: "Google")
        let vault = InMemoryCredentialVault()
        try vault.save(
            .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "revoked", expiresAt: .distantPast)),
            for: account.id
        )
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(http.requests.map(\.url.absoluteString), ["https://oauth2.googleapis.com/token"])
        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(.antigravity).localizedDescription)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("Expected the credential to survive") }
        XCTAssertEqual(saved.accessToken, "old-access", "a refused refresh must not touch the stored credential")
    }
    func testClaudeRefusedRefreshTokenReadsAsExpiredSignIn() async throws {
        try await assertRefusedRefreshTokenReadsAsExpiredSignIn(kind: .claude, tokenURL: "https://platform.claude.com/v1/oauth/token")
    }

    func testGrokRefusedRefreshTokenReadsAsExpiredSignIn() async throws {
        try await assertRefusedRefreshTokenReadsAsExpiredSignIn(kind: .grok, tokenURL: "https://auth.x.ai/oauth2/token")
    }

    func testClaudeRefreshRefusedWithoutInvalidGrantStaysARequestFailure() async throws {
        let account = Account(kind: .claude, label: "Personal")
        let vault = InMemoryCredentialVault()
        try vault.save(
            .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)),
            for: account.id
        )
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_request"}"#.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(snapshot.failure?.message, ProviderError.requestFailed(400).localizedDescription)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("Expected the credential to survive") }
        XCTAssertEqual(saved.accessToken, "old-access")
    }

    private func assertRefusedRefreshTokenReadsAsExpiredSignIn(kind: ProviderKind, tokenURL: String) async throws {
        let account = Account(kind: kind, label: "Personal")
        let vault = InMemoryCredentialVault()
        try vault.save(
            .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "revoked", expiresAt: .distantPast)),
            for: account.id
        )
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(http.requests.map(\.url.absoluteString), [tokenURL])
        guard let text = snapshot.failure?.message else { return XCTFail("Expected an error snapshot") }
        XCTAssertEqual(text, ProviderError.signInExpired(kind).localizedDescription)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("Expected the credential to survive") }
        XCTAssertEqual(saved.accessToken, "old-access", "a refused refresh must not touch the stored credential")
    }
}
