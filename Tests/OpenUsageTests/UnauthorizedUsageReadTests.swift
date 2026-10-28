import Foundation
import os
import XCTest
@testable import OpenUsage

private struct OAuthProvider {
    let kind: ProviderKind
    let tokenURL: URL
    let usageURL: URL
    let usage: String
}

/// A usage read the provider answers with 401 renews the sign-in once through the account's own refresh
/// token and is retried with the new access token; a second 401 is the expired sign-in, and no other
/// answer renews.
@MainActor
final class UnauthorizedUsageReadTests: XCTestCase {
    private static let providers = [
        OAuthProvider(
            kind: .claude, tokenURL: ClaudeLogin.tokenURL, usageURL: ClaudeUsageClient.usageURL,
            usage: #"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#
        ),
        OAuthProvider(kind: .codex, tokenURL: CodexLogin.tokenURL, usageURL: CodexUsageClient.usageURL, usage: #"{"rate_limit":{}}"#),
        OAuthProvider(
            kind: .grok, tokenURL: GrokLogin.tokenURL, usageURL: GrokUsageClient.creditsConfigURL,
            usage: #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-30T21:36:52+00:00","end":"2026-07-07T21:36:52+00:00"},"creditUsagePercent":40}}"#
        ),
    ]

    func testA401RenewsTheSignInOnceAndRetriesTheReadWithTheNewToken() async throws {
        for provider in Self.providers {
            for expiresAt in [nil, Date().addingTimeInterval(3600)] {
                let name = "\(provider.kind) expiring \(expiresAt == nil ? "at an unknown time" : "in an hour")"
                let (result, http, saved) = try await Self.refresh(provider, expiresAt: expiresAt) { attempt in
                    attempt == 1 ? HTTPResponse(statusCode: 401, headers: [:], body: Data()) : Self.ok(provider.usage)
                }
                XCTAssertNil(result.failure?.message, name)
                XCTAssertEqual(http.requests.count { $0.url == provider.tokenURL }, 1, name)
                XCTAssertEqual(
                    http.requests.filter { $0.url == provider.usageURL }.map { $0.headers["Authorization"] },
                    ["Bearer old-access", "Bearer new-access"], name
                )
                XCTAssertEqual(saved?.accessToken, "new-access", name)
                XCTAssertEqual(saved?.refreshToken, "rotated-refresh", name)
            }
        }
    }

    func testASecondUnauthorizedAnswerIsTheExpiredSignIn() async throws {
        for provider in Self.providers {
            let (result, http, saved) = try await Self.refresh(provider, expiresAt: nil) { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(result.failure?.message, ProviderError.signInExpired(provider.kind).localizedDescription, "\(provider.kind)")
            XCTAssertEqual(http.requests.count { $0.url == provider.tokenURL }, 1, "\(provider.kind): renewed once, never in a loop")
            XCTAssertEqual(http.requests.count { $0.url == provider.usageURL }, 2, "\(provider.kind)")
            XCTAssertEqual(saved?.accessToken, "new-access", "\(provider.kind): the grant the provider gave is kept")
        }
    }

    func testOnlyA401RenewsTheSignIn() async throws {
        for provider in Self.providers {
            for status in [403, 429, 500] {
                let name = "\(provider.kind) \(status)"
                let (result, http, saved) = try await Self.refresh(provider, expiresAt: nil) { _ in
                    HTTPResponse(statusCode: status, headers: [:], body: Data())
                }
                XCTAssertNotNil(result.failure, name)
                XCTAssertEqual(http.requests.count { $0.url == provider.tokenURL }, 0, name)
                XCTAssertEqual(http.requests.count { $0.url == provider.usageURL }, 1, name)
                XCTAssertEqual(saved?.accessToken, "old-access", name)
            }
        }
    }

    private static func refresh(
        _ provider: OAuthProvider, expiresAt: Date?, usage: @escaping @Sendable (Int) -> HTTPResponse
    ) async throws -> (result: Result<ProviderSnapshot, RefreshFailure>, http: RoutingHTTPClient, saved: OAuthTokens?) {
        let account = Account(kind: provider.kind, label: "Personal")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: expiresAt)), for: account.id)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case provider.tokenURL: ok(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#)
            case provider.usageURL: usage(attempts.withLock { $0 += 1; return $0 })
            default: HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let result = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh()
        guard case .oauth(let saved)? = try vault.load(account.id) else { return (result, http, nil) }
        return (result, http, saved)
    }

    private nonisolated static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
