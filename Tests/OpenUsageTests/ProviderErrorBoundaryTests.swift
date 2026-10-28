import Foundation
import XCTest
@testable import OpenUsage

/// A refresh triages the HTTP status before it reads a body: a 401 or 403 is an expired sign-in
/// whatever the body says, any other non-2xx is a request failure that names its status, a transport
/// error keeps its own message, and a failed best-effort request costs the plan, never the meters.
private let openCodeUsage = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#
private let ollamaBalance = #"{"included":{"balance_usd":72.5,"allowance_usd":100,"period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},"purchased":{"balance_usd":25}}"#
private let openRouterCredits = #"{"data":{"total_credits":100,"total_usage":22.23}}"#
private let openRouterKey = #"{"data":{"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12,"limit":1,"limit_remaining":0.25,"is_free_tier":false}}"#

private func response(_ status: Int, _ body: String = "") -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
}

@MainActor
final class ProviderErrorBoundaryTests: XCTestCase {
    private static let keyedKinds: [(ProviderKind, AccountCredential)] = [
        (.copilot, .oauth(OAuthTokens(accessToken: "token"))),
        (.ollama, .apiKey("key")),
        (.opencodeGo, .apiKey("key")),
        (.openrouter, .apiKey("key")),
        (.zai, .apiKey("key"))
    ]

    private func refresh(
        _ kind: ProviderKind, credential: AccountCredential = .apiKey("key"),
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> ProviderSnapshot {
        let account = Account(kind: kind, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(credential, for: account.id)
        return await AccountProviderRuntime(account: account, vault: vault, http: RoutingHTTPClient(handler: handler)).refresh()
    }

    func testAnUnauthorizedResponseIsAnExpiredSignInWhateverTheBodySays() async throws {
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in response(401, openCodeUsage) }
            XCTAssertEqual(snapshot.errorMessage, ProviderError.signInExpired(kind).localizedDescription, "\(kind)")
            XCTAssertTrue(snapshot.lines.isEmpty, "\(kind)")
        }
    }

    func testAMissingKeychainItemIsAnExpiredSignIn() async {
        let account = Account(kind: .claude, label: "Work")
        let runtime = AccountProviderRuntime(account: account, vault: InMemoryCredentialVault(), http: RoutingHTTPClient { _ in response(200) })

        let snapshot = await runtime.refresh()

        XCTAssertEqual(snapshot.errorMessage, ProviderError.signInExpired(.claude).localizedDescription)
    }

    func testAServerErrorNamesItsStatus() async throws {
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in response(503, "<html>down</html>") }
            XCTAssertEqual(snapshot.errorMessage, ProviderError.requestFailed(503).localizedDescription, "\(kind)")
        }
    }

    func testATransportErrorKeepsItsOwnMessage() async throws {
        let offline = URLError(.notConnectedToInternet)
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in throw offline }
            XCTAssertEqual(snapshot.errorMessage, offline.localizedDescription, "\(kind)")
        }
    }

    func testAFailedPlanLookupCostsThePlanNotTheMeters() async throws {
        let ollama = try await refresh(.ollama) { request in
            request.url.absoluteString.hasSuffix("/api/balance")
                ? response(200, ollamaBalance)
                : response(500, #"{"Plan":"pro"}"#)
        }
        XCTAssertNil(ollama.errorMessage)
        XCTAssertNil(ollama.plan)
        XCTAssertEqual(ollama.lines.map(\.label), ["Monthly", "Purchased Credits"])

        let zai = try await refresh(.zai) { request in
            request.url.absoluteString.contains("quota")
                ? response(200, #"{"data":{"limits":[]}}"#)
                : response(401, #"{"data":{"plan":"GLM Coding Pro"}}"#)
        }
        XCTAssertNil(zai.errorMessage)
        XCTAssertNil(zai.plan)
    }

    func testOpenCodeWithoutAGoSubscriptionSaysSo() async throws {
        let snapshot = try await refresh(.opencodeGo) { _ in
            response(403, #"{"type":"error","error":{"type":"EntitlementError","message":"no subscription"}}"#)
        }
        XCTAssertEqual(snapshot.errorMessage, "No OpenCode Go subscription on this account.")
    }

    func testOpenRouterCallsTheKeyInvalidOnlyWhenBothEndpointsRejectIt() async throws {
        let rejected = try await refresh(.openrouter) { _ in response(401, #"{"error":{"message":"No auth credentials found","code":401}}"#) }
        XCTAssertEqual(rejected.errorMessage, ProviderError.signInExpired(.openrouter).localizedDescription)

        let gated = try await refresh(.openrouter) { request in
            request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? response(403, #"{"error":{"message":"forbidden","code":403}}"#)
                : response(200, openRouterKey)
        }
        XCTAssertNil(gated.errorMessage)
        XCTAssertEqual(gated.lines.map(\.label), ["Today", "This Week", "This Month"])
    }

    func testOpenRouterShowsTheFailureWhenNeitherEndpointAnswers() async throws {
        let down = try await refresh(.openrouter) { request in
            request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? response(503, "<html>down</html>")
                : response(401, #"{"error":{"message":"No auth credentials found","code":401}}"#)
        }
        XCTAssertEqual(down.errorMessage, ProviderError.requestFailed(503).localizedDescription)

        let partial = try await refresh(.openrouter) { request in
            request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? response(200, openRouterCredits)
                : response(503, "")
        }
        XCTAssertNil(partial.errorMessage)
        XCTAssertEqual(partial.lines.map(\.label), ["Balance"])

        let unreadable = try await refresh(.openrouter) { _ in response(200, #"{"ok":true}"#) }
        XCTAssertEqual(unreadable.errorMessage, ProviderError.invalidResponse.localizedDescription)
    }
}
