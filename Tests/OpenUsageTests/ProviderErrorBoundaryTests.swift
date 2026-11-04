import Foundation
import XCTest
@testable import OpenUsage

private let openCodeUsage = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#
private let ollamaBalance = #"{"included":{"balance_usd":72.5,"allowance_usd":100,"period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},"purchased":{"balance_usd":25}}"#

@MainActor
final class ProviderErrorBoundaryTests: XCTestCase {
    private static let keyedKinds: [(ProviderKind, AccountCredential)] = [
        (.copilot, .oauth(OAuthTokens(accessToken: "token"))),
        (.devin, .oauth(OAuthTokens(accessToken: "key"))),
        (.ollama, .apiKey("key")),
        (.opencodeGo, .apiKey("key")),
        (.openrouter, .apiKey("key")),
        (.zai, .apiKey("key"))
    ]

    private func refresh(
        _ kind: ProviderKind, credential: AccountCredential = .apiKey("key"),
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> Result<ProviderSnapshot, RefreshFailure> {
        let account = Account(kind: kind, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(credential, for: account.id)
        return await AccountProviderRuntime(account: account, vault: vault, http: RoutingHTTPClient(handler: handler)).refresh()
    }

    func testAnUnauthorizedResponseIsARefusedCredentialWhateverTheBodySays() async throws {
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in .json(openCodeUsage, status: 401) }
            let expected = if case .oauth = credential {
                "\(kind.displayName) sign-in expired. Sign in again to keep reading usage."
            } else {
                "\(kind.displayName) rejected the API key. Replace it on the account's page."
            }
            XCTAssertEqual(snapshot.failure?.message, expected, "\(kind)")
        }
    }

    func testAMissingKeychainItemSaysHowToFixThatAccount() async {
        let accounts = [
            (Account(kind: .claude, label: "Work"), "Claude sign-in expired. Sign in again to keep reading usage."),
            (Account(kind: .openrouter, label: "Work"), "OpenRouter rejected the API key. Replace it on the account's page."),
            (Account(kind: .copilot, label: "acme", organization: "acme"), "GitHub rejected the token. Replace it on the account's page.")
        ]
        for (account, message) in accounts {
            let runtime = AccountProviderRuntime(account: account, vault: InMemoryCredentialVault(), http: RoutingHTTPClient { _ in .json("") })
            let snapshot = await runtime.refresh()
            XCTAssertEqual(snapshot.failure?.message, message)
        }
    }

    func testAServerErrorNamesItsStatus() async throws {
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in .json("<html>down</html>", status: 503) }
            XCTAssertEqual(snapshot.failure?.message, ProviderError.requestFailed(503).localizedDescription, "\(kind)")
        }
    }

    func testATransportErrorKeepsItsOwnMessage() async throws {
        let offline = URLError(.notConnectedToInternet)
        for (kind, credential) in Self.keyedKinds {
            let snapshot = try await refresh(kind, credential: credential) { _ in throw offline }
            XCTAssertEqual(snapshot.failure?.message, offline.localizedDescription, "\(kind)")
        }
    }

    func testAFailedPlanLookupCostsThePlanNotTheMeters() async throws {
        let ollama = try await refresh(.ollama) { request in
            request.url.absoluteString.hasSuffix("/api/balance")
                ? .json(ollamaBalance)
                : .json(#"{"Plan":"pro"}"#, status: 500)
        }.get()
        XCTAssertNil(ollama.plan)
        XCTAssertEqual(ollama.lines.map(\.label), ["Monthly", "Purchased Credits"])

        let zai = try await refresh(.zai) { request in
            request.url.absoluteString.contains("quota")
                ? .json(#"{"data":{"limits":[]}}"#)
                : .json(#"{"data":{"plan":"GLM Coding Pro"}}"#, status: 401)
        }.get()
        XCTAssertNil(zai.plan)
    }

    func testOpenCodeWithoutAGoSubscriptionSaysSo() async throws {
        let snapshot = try await refresh(.opencodeGo) { _ in
            .json(#"{"type":"error","error":{"type":"EntitlementError","message":"no subscription"}}"#, status: 403)
        }
        XCTAssertEqual(snapshot.failure?.message, "No OpenCode Go subscription on this account.")
    }

    func testOpenRouterShowsTheFailureOfAnyRead() async throws {
        let creditsDown = try await refresh(.openrouter) { request in
            request.url.absoluteString == OpenRouterUsageClient.creditsURL ? .json("", status: 503) : OpenRouterFixtures.managementAccount(request)
        }
        XCTAssertEqual(creditsDown.failure?.message, ProviderError.requestFailed(503).localizedDescription)

        let secondPageDown = try await refresh(.openrouter) { request in
            OpenRouterFixtures.offset(request) == "100" ? .json("", status: 503) : OpenRouterFixtures.managementAccount(request)
        }
        XCTAssertEqual(secondPageDown.failure?.message, ProviderError.requestFailed(503).localizedDescription)

        let unreadable = try await refresh(.openrouter) { _ in .json(#"{"ok":true}"#) }
        XCTAssertEqual(unreadable.failure?.message, ProviderError.invalidResponse.localizedDescription)
    }
}
