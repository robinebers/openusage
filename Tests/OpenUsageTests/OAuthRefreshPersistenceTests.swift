import Foundation
import Security
import XCTest
@testable import OpenUsage

@MainActor
final class OAuthRefreshPersistenceTests: XCTestCase {
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

    func testAFailedRenewalKeepsTheStoredSignInAndReadsAsItsCause() async throws {
        let cases: [(answer: @Sendable () throws -> HTTPResponse, message: (ProviderKind) -> String?, kind: RefreshFailure.Kind?)] = [
            ({ .json(#"{"error":"invalid_grant"}"#, status: 400) }, { ProviderError.signInExpired($0).localizedDescription }, nil),
            ({ .json(#"{"error":"invalid_grant"}"#, status: 401) }, { ProviderError.signInExpired($0).localizedDescription }, nil),
            ({ .json(#"{"error":"invalid_grant"}"#, status: 403) }, { ProviderError.signInExpired($0).localizedDescription }, nil),
            ({ .json(#"{"error":"invalid_request"}"#, status: 400) }, { _ in ProviderError.requestFailed(400).localizedDescription }, .refused),
            ({ .json("<html>Service Unavailable</html>", status: 503) }, { _ in ProviderError.requestFailed(503).localizedDescription }, .refused),
            (
                { HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data()) },
                { _ in ProviderError.rateLimited(retryAfter: 120).localizedDescription }, .rateLimited(retryAfter: 120)
            ),
            ({ throw URLError(.notConnectedToInternet) }, { _ in nil }, .unreachable),
            ({ .json(#"{"token_type":"Bearer"}"#) }, { _ in ProviderError.invalidResponse.localizedDescription }, nil)
        ]
        let renewals: [(kind: ProviderKind, tokenURL: URL)] = [
            (.claude, ClaudeLogin.tokenURL),
            (.codex, CodexLogin.tokenURL),
            (.cursor, CursorUsageClient.refreshURL),
            (.antigravity, AntigravityLogin.tokenURL),
            (.grok, GrokLogin.tokenURL)
        ]
        for (index, (answer, message, failureKind)) in cases.enumerated() {
            for (kind, tokenURL) in renewals {
                let account = Account(kind: kind, label: "Personal")
                let vault = InMemoryCredentialVault()
                let stored = AccountCredential.oauth(
                    OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
                )
                try vault.save(stored, for: account.id)
                let http = RoutingHTTPClient { _ in try answer() }

                let failure = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().failure

                XCTAssertEqual(http.requests.map(\.url), [tokenURL], "case \(index) \(kind)")
                XCTAssertEqual(try vault.load(account.id), stored, "case \(index) \(kind)")
                if let expected = message(kind) { XCTAssertEqual(failure?.message, expected, "case \(index) \(kind)") }
                if let failureKind { XCTAssertEqual(failure?.kind, failureKind, "case \(index) \(kind)") }
            }
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
            return .json(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#)
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
        let http = RoutingHTTPClient { _ in .json(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let read: (OAuthTokens) async throws -> HTTPResponse = { tokens in
            .json("{}", status: tokens.accessToken == "old-access" ? 401 : 200)
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
            return .json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"org"}}"#)
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

    func testARenewalTheKeychainRefusesIsUsedAndSavedOnTheNextLoad() async throws {
        let renewals: [(ProviderKind, @MainActor (AccountProviderRuntime, OAuthTokens) async throws -> OAuthTokens)] = [
            (.claude, { try await $0.freshTokens(.oauth($1), grant: ClaudeLogin.refresh) }),
            (.cursor, { try await $0.refreshCursorTokens($1) })
        ]
        for (kind, renew) in renewals {
            let account = Account(kind: kind, label: "Personal")
            let vault = FailingVault()
            let old = OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
            try vault.save(.oauth(old), for: account.id)
            let http = RoutingHTTPClient { _ in .json(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#) }
            let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

            vault.updateError.value = KeychainVaultError.status(errSecInteractionNotAllowed)
            let renewed = try await renew(runtime, old)
            vault.updateError.value = nil
            let next = try await runtime.loadCredential()

            XCTAssertEqual(renewed.accessToken, "new-access", "\(kind)")
            XCTAssertEqual(next, .oauth(renewed), "\(kind): the next pass uses the renewed sign-in, not the spent refresh token")
            XCTAssertEqual(try vault.load(account.id), .oauth(renewed), "\(kind): and saves it once the Keychain takes it")
        }
    }

    func testAnEarlyRenewalTheProviderRateLimitsWaitsOutItsRetryAfter() async throws {
        let renewals: [(ProviderKind, TimeInterval, @MainActor (AccountProviderRuntime, OAuthTokens) async throws -> OAuthTokens)] = [
            (.claude, 120, { try await $0.freshTokens(.oauth($1), grant: ClaudeLogin.refresh) }),
            (.cursor, 86_400, { try await $0.cursorTokens(.oauth($1)) })
        ]
        for (kind, expiresIn, renew) in renewals {
            let start = Date()
            let clock = TestSwitch(start)
            let account = Account(kind: kind, label: "Personal")
            let vault = InMemoryCredentialVault()
            let current = OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: start.addingTimeInterval(expiresIn))
            try vault.save(.oauth(current), for: account.id)
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data()) }
            let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.value })

            _ = try await renew(runtime, current)
            _ = try await renew(runtime, current)
            XCTAssertEqual(http.requests.count, 1, "\(kind): no early renewal inside the Retry-After")
            clock.value = start.addingTimeInterval(61)
            let tokens = try await renew(runtime, current)

            XCTAssertEqual(tokens, current, "\(kind)")
            XCTAssertEqual(http.requests.count, 2, "\(kind): asked again once the Retry-After passed")
        }
    }
}
