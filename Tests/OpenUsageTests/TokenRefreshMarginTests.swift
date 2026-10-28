import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokenRefreshMarginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeTokenExpiringWithinTheMarginIsRefreshedBeforeTheUsageRead() async throws {
        let (snapshot, http, saved) = try await refreshClaude(expiringIn: 2 * 60)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://platform.claude.com/v1/oauth/token")
        let usage = try XCTUnwrap(http.requests.first { $0.url.path == "/api/oauth/usage" })
        XCTAssertEqual(usage.headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(28_800), "the provider's own expiry is stored")
    }

    func testClaudeTokenWithTimeToSpareIsNotRefreshed() async throws {
        let (snapshot, http, _) = try await refreshClaude(expiringIn: 10 * 60)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertFalse(http.requests.contains { $0.url.host() == "platform.claude.com" })
    }

    func testCodexTokenExpiringWithinTheMarginIsRefreshedBeforeTheUsageRead() async throws {
        let http = try await refreshCodex(expiringIn: 60)
        XCTAssertEqual(http.requests.first?.url, CodexLogin.tokenURL)
        let usage = try XCTUnwrap(http.requests.first { $0.url == CodexUsageClient.usageURL })
        XCTAssertEqual(usage.headers["Authorization"], "Bearer new-access")
    }

    func testCodexTokenWithTimeToSpareIsNotRefreshed() async throws {
        let http = try await refreshCodex(expiringIn: 10 * 60)
        XCTAssertFalse(http.requests.contains { $0.url == CodexLogin.tokenURL })
    }

    private func refreshClaude(expiringIn seconds: TimeInterval) async throws -> (ProviderSnapshot, RoutingHTTPClient, OAuthTokens) {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(
            accessToken: "old-access", refreshToken: "refresh", expiresAt: now.addingTimeInterval(seconds)
        )), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/v1/oauth/token":
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new-access","expires_in":28800}"#.utf8))
            case "/api/oauth/usage":
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":12}}"#.utf8))
            default:
                HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let snapshot = await AccountProviderRuntime(account: account, vault: vault, http: http, now: { [now] in now }).refresh()
        guard case .oauth(let saved)? = try vault.load(account.id) else { throw XCTSkip("no credential") }
        return (snapshot, http, saved)
    }

    private func refreshCodex(expiringIn seconds: TimeInterval) async throws -> RoutingHTTPClient {
        let account = Account(kind: .codex, label: "Codex")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(
            accessToken: "old-access", refreshToken: "refresh", expiresAt: now.addingTimeInterval(seconds)
        )), for: account.id)
        let http = RoutingHTTPClient { request in
            if request.url == CodexLogin.tokenURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new-access","refresh_token":"next"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit":{}}"#.utf8))
        }
        _ = await AccountProviderRuntime(account: account, vault: vault, http: http, now: { [now] in now }).refresh()
        return http
    }
}
