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

    func testOutageWhileRenewingEarlyKeepsTheStillValidToken() async throws {
        let now = Date()
        let account = Account(kind: .antigravity, label: "Google")
        let vault = InMemoryCredentialVault()
        let stored = AccountCredential.oauth(
            OAuthTokens(accessToken: "old-access", refreshToken: "google-refresh", expiresAt: now.addingTimeInterval(120))
        )
        try vault.save(stored, for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url.absoluteString {
            case "https://oauth2.googleapis.com/token":
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            case "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary":
                let body = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { now })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests.filter { $0.url == AntigravityLogin.tokenURL }.count, 1)
        let quotaRequests = http.requests.filter { $0.url.path.hasSuffix("retrieveUserQuotaSummary") }
        XCTAssertFalse(quotaRequests.isEmpty)
        XCTAssertTrue(quotaRequests.allSatisfy { $0.headers["Authorization"] == "Bearer old-access" }, "\(quotaRequests)")
        XCTAssertEqual(try vault.load(account.id), stored)
    }

    func testRenewalRefusedWithInvalidGrantIsAnExpiredSignIn() async throws {
        for status in [400, 401, 403] {
            let failures = try await renewalFailures { Self.json(#"{"error":"invalid_grant"}"#, status: status) }
            for (kind, _) in Self.renewals {
                XCTAssertEqual(failures[kind]?.message, ProviderError.signInExpired(kind).localizedDescription, "\(kind) \(status)")
            }
        }
    }

    func testRenewalRejectedForAnotherReasonIsARequestFailure() async throws {
        let failures = try await renewalFailures { Self.json(#"{"error":"invalid_request"}"#, status: 400) }
        for (kind, _) in Self.renewals {
            XCTAssertEqual(
                failures[kind],
                RefreshFailure(message: ProviderError.requestFailed(400).localizedDescription, kind: .refused),
                "\(kind)"
            )
        }
    }

    func testRenewalDuringAnOutageIsARequestFailure() async throws {
        let failures = try await renewalFailures { Self.json("<html>Service Unavailable</html>", status: 503) }
        for (kind, _) in Self.renewals {
            XCTAssertEqual(
                failures[kind],
                RefreshFailure(message: ProviderError.requestFailed(503).localizedDescription, kind: .refused),
                "\(kind)"
            )
        }
    }

    func testRenewalRateLimitWaitsAsTheProviderAsks() async throws {
        let failures = try await renewalFailures { HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data()) }
        for (kind, _) in Self.renewals {
            XCTAssertEqual(
                failures[kind],
                RefreshFailure(
                    message: ProviderError.rateLimited(retryAfter: 120).localizedDescription,
                    kind: .rateLimited(retryAfter: 120)
                ),
                "\(kind)"
            )
        }
    }

    func testRenewalWhileOfflineIsUnreachable() async throws {
        let failures = try await renewalFailures { throw URLError(.notConnectedToInternet) }
        for (kind, _) in Self.renewals {
            XCTAssertEqual(failures[kind]?.kind, .unreachable, "\(kind)")
        }
    }

    func testRenewalAnswerWithoutATokenIsAnInvalidResponse() async throws {
        let failures = try await renewalFailures { Self.json(#"{"token_type":"Bearer"}"#) }
        for (kind, _) in Self.renewals {
            XCTAssertEqual(failures[kind]?.message, ProviderError.invalidResponse.localizedDescription, "\(kind)")
        }
    }

    func testConcurrentRenewalsForOneAccountSendItsRefreshTokenOnce() async throws {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        let expired = AccountCredential.oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast))
        try vault.save(expired, for: account.id)
        let renewal = HeldResponse()
        let http = RoutingHTTPClient { _ in
            await renewal.hold()
            return Self.json(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#)
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let first = Task { try await runtime.freshTokens(expired, grant: ClaudeLogin.refresh) }
        await renewal.waitUntilHeld()
        let second = Task { try await runtime.freshTokens(expired, grant: ClaudeLogin.refresh) }
        await Task.yield()
        await renewal.release()

        let tokens = try await [first.value, second.value]
        XCTAssertEqual(tokens.map(\.accessToken), ["new-access", "new-access"])
        XCTAssertEqual(http.requests.map(\.url), [ClaudeLogin.tokenURL], "the second caller waits for the first renewal")
    }

    func testALate401AfterAnotherRenewalRetriesWithTheStoredTokens() async throws {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        let old = AccountCredential.oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh"))
        try vault.save(old, for: account.id)
        let http = RoutingHTTPClient { _ in Self.json(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let read: (OAuthTokens) async throws -> HTTPResponse = { tokens in
            Self.json("{}", status: tokens.accessToken == "old-access" ? 401 : 200)
        }

        _ = try await runtime.authorizedRead(old, grant: ClaudeLogin.refresh, read: read)
        let late = try await runtime.authorizedRead(old, grant: ClaudeLogin.refresh, read: read)

        XCTAssertEqual(late.response.statusCode, 200)
        XCTAssertEqual(late.tokens.accessToken, "new-access")
        XCTAssertEqual(http.requests.map(\.url), [ClaudeLogin.tokenURL], "the old refresh token is sent once")
    }

    func testClaudeIdentityWriteBackKeepsATokenRenewedDuringTheProfileRead() async throws {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh")), for: account.id)
        let profile = HeldResponse()
        let http = RoutingHTTPClient { request in
            guard request.url.path == "/api/oauth/profile" else { return HTTPResponse(statusCode: 404, headers: [:], body: Data()) }
            await profile.hold()
            return Self.json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"org"}}"#)
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let renewed = OAuthTokens(accessToken: "new-access", refreshToken: "rotated-refresh")

        let hourly = Task { await runtime.refreshHourlyReads(of: ProviderSnapshot(providerID: account.cardID, displayName: "Claude", lines: [])) }
        await profile.waitUntilHeld()
        try vault.save(.oauth(renewed), for: account.id)
        await profile.release()
        _ = await hourly.value

        var identified = renewed
        identified.extras[OAuthTokens.identityKey] = "acct/org"
        XCTAssertEqual(try vault.load(account.id), .oauth(identified))
    }

    private static let renewals: [(kind: ProviderKind, tokenURL: URL)] = [
        (.claude, ClaudeLogin.tokenURL),
        (.codex, CodexLogin.tokenURL),
        (.cursor, CursorUsageClient.refreshURL),
        (.antigravity, AntigravityLogin.tokenURL),
        (.grok, GrokLogin.tokenURL)
    ]

    private func renewalFailures(
        _ answer: @escaping @Sendable () throws -> HTTPResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [ProviderKind: RefreshFailure] {
        var failures: [ProviderKind: RefreshFailure] = [:]
        for (kind, tokenURL) in Self.renewals {
            let account = Account(kind: kind, label: "Personal")
            let vault = InMemoryCredentialVault()
            let stored = AccountCredential.oauth(
                OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
            )
            try vault.save(stored, for: account.id)
            let http = RoutingHTTPClient { _ in try answer() }

            failures[kind] = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().failure

            XCTAssertEqual(http.requests.map(\.url), [tokenURL], "\(kind)", file: file, line: line)
            XCTAssertEqual(try vault.load(account.id), stored, "\(kind)", file: file, line: line)
        }
        return failures
    }

    nonisolated private static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }
}
