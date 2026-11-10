import Foundation
import XCTest
@testable import OpenUsage

/// A refresh never asks for more than the sign-in did: Claude's refresh sends the sign-in's own scope
/// string, and the others send no `scope`, which OAuth reads as the granted set. `ProviderLoginTests`
/// pins the scope string each sign-in sends.
final class ProviderScopeTests: XCTestCase {
    func testClaudeRefreshAsksForTheSignInScopes() async throws {
        let http = Self.tokenEndpoint()

        _ = try await ClaudeLogin.refresh("refresh", http: http, now: Date())

        let request = try XCTUnwrap(http.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["scope"] as? String, "user:profile user:inference")
        XCTAssertEqual(body["client_id"] as? String, ClaudeLogin.clientID)
    }

    func testClaudeRefreshOfAProfileOnlySignInFallsBackToItsOwnScopes() async throws {
        let http = RoutingHTTPClient { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
            return body["scope"] as? String == "user:profile"
                ? HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
                : HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_scope"}"#.utf8))
        }

        let grant = try await ClaudeLogin.refresh("refresh", http: http, now: Date())

        XCTAssertEqual(grant.accessToken, "new")
        let scopes = try http.requests.map { request in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])["scope"] as? String
        }
        XCTAssertEqual(scopes, ["user:profile user:inference", "user:profile"])
    }

    func testGrokRefreshSendsNoScope() async throws {
        let http = Self.tokenEndpoint()

        _ = try await GrokLogin.refresh("refresh", http: http, now: Date())

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
