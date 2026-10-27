import Foundation
import XCTest
@testable import OpenUsage

/// Pins what each OAuth sign-in asks a provider for, and that a refresh never asks for more than the
/// sign-in did. A scope added here is a scope every user grants, so the strings are compared whole.
final class ProviderScopeTests: XCTestCase {
    func testClaudeAsksForProfileOnly() {
        XCTAssertEqual(ClaudeLogin.scopes, "user:profile")
    }

    func testClaudeRefreshAsksForTheSignInScopes() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }
        let config = ClaudeOAuthConfig(
            usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            refreshURL: ClaudeLogin.tokenURL,
            clientID: ClaudeLogin.clientID
        )

        _ = try await ClaudeUsageClient(httpClient: http).refreshToken("refresh", config: config)

        let request = try XCTUnwrap(http.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["scope"] as? String, ClaudeLogin.scopes)
        XCTAssertEqual(body["client_id"] as? String, ClaudeLogin.clientID)
    }

    func testAntigravityAsksForCloudCodeAndEmailOnly() {
        XCTAssertEqual(
            AntigravityLogin.scopes,
            "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"
        )
    }

    func testAntigravityRefreshSendsNoScope() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }

        _ = await AntigravityUsageClient(http: http).refreshGoogleToken("refresh")

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    func testCodexAsksForPlainOIDC() {
        XCTAssertEqual(CodexLogin.scopes, "openid profile email offline_access")
    }

    func testCodexRefreshSendsNoScope() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }

        _ = try await CodexUsageClient(http: http).refreshToken("refresh")

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    func testCopilotAsksForReadUserOnly() {
        XCTAssertEqual(CopilotLogin.scopes, "read:user")
    }

    func testGrokAsksForTheGrokCLIScopes() {
        XCTAssertEqual(GrokLogin.scopes, "openid profile email offline_access grok-cli:access api:access")
    }

    func testGrokRefreshSendsNoScope() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }

        _ = try await GrokUsageClient(httpClient: http).refreshToken("refresh", clientID: GrokLogin.clientID)

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    private static func formFields(_ request: HTTPRequest) -> [String: String] {
        guard
            let body = request.body.flatMap({ String(data: $0, encoding: .utf8) }),
            let items = URLComponents(string: "https://example.invalid/?\(body)")?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
    }
}
