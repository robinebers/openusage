import Foundation
import XCTest
@testable import OpenUsage

/// A refresh never asks for more than the sign-in did: Claude's refresh sends the sign-in's own scope
/// string, and the others send no `scope`, which OAuth reads as the granted set. `ProviderLoginTests`
/// pins the scope string each sign-in sends.
final class ProviderScopeTests: XCTestCase {
    func testClaudeRefreshAsksForTheSignInScopes() async throws {
        let http = Self.tokenEndpoint()

        _ = try await ClaudeUsageClient(httpClient: http).refreshToken("refresh")

        let request = try XCTUnwrap(http.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["scope"] as? String, "user:profile")
        XCTAssertEqual(body["client_id"] as? String, ClaudeLogin.clientID)
    }

    func testAntigravityRefreshSendsNoScope() async throws {
        let http = Self.tokenEndpoint()

        _ = await AntigravityUsageClient(http: http).refreshGoogleToken("refresh")

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    func testCodexRefreshSendsNoScope() async throws {
        let http = Self.tokenEndpoint()

        _ = try await CodexUsageClient(http: http).refreshToken("refresh")

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    func testGrokRefreshSendsNoScope() async throws {
        let http = Self.tokenEndpoint()

        _ = try await GrokUsageClient(httpClient: http).refreshToken("refresh", clientID: GrokLogin.clientID)

        XCTAssertNil(Self.formFields(try XCTUnwrap(http.requests.first))["scope"])
    }

    private static func tokenEndpoint() -> RoutingHTTPClient {
        RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }
    }

    private static func formFields(_ request: HTTPRequest) -> [String: String] {
        guard
            let body = request.body.flatMap({ String(data: $0, encoding: .utf8) }),
            let items = URLComponents(string: "https://example.invalid/?\(body)")?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
    }
}
