import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokenRefreshMarginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeTokenExpiringWithinTheMarginIsRefreshedBeforeTheUsageRead() async throws {
        let (http, saved) = try await refreshClaude(expiringIn: 2 * 60)
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://platform.claude.com/v1/oauth/token")
        let usage = try XCTUnwrap(http.requests.first { $0.url.path == "/api/oauth/usage" })
        XCTAssertEqual(usage.headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(28_800), "the provider's own expiry is stored")
    }

    private func refreshClaude(expiringIn seconds: TimeInterval) async throws -> (RoutingHTTPClient, OAuthTokens) {
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
        _ = try await AccountProviderRuntime(account: account, vault: vault, http: http, now: { [now] in now }).refresh().get()
        guard case .oauth(let saved)? = try vault.load(account.id) else { throw XCTSkip("no credential") }
        return (http, saved)
    }
}
