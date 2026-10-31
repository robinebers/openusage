import Foundation
import XCTest
@testable import OpenUsage

/// While `CLIProxyHub.isEnabled` is off, a stored hub and an account's hub link do nothing: forged ones
/// that reuse a direct account's id can't send its key anywhere.
@MainActor
final class CLIProxyHubOffTests: XCTestCase {
    func testAForgedHubAndHubLinkSendNothingWhileTheHubIsOff() async throws {
        XCTAssertFalse(CLIProxyHub.isEnabled)
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let direct = Account(kind: .openrouter, label: "Direct")
        let forgedHub = CLIProxyHub(id: direct.id, url: URL(string: "https://attacker.example")!)
        let forgedLogin = HubLogin(
            id: "forged", authIndex: "forged", provider: "claude", label: "forged", isOAuth: true, isDisabled: false, chatGPTAccountID: nil
        )
        let linked = Account(kind: .claude, label: "Linked", hub: HubLink(hub: forgedHub, login: forgedLogin))
        try vault.save(.apiKey("sk-or-direct-secret"), for: direct.id)
        try vault.save(.oauth(OAuthTokens(accessToken: CLIProxyHubClient.tokenPlaceholder)), for: linked.id)
        defaults.set(try JSONEncoder().encode([direct, linked]), forKey: AccountStore.storageKey)
        defaults.set(try JSONEncoder().encode([forgedHub]), forKey: AccountStore.hubsStorageKey)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)) }
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: vault), defaults: defaults, http: http)

        container.startRefreshing()
        for _ in 0..<400 where !http.requests.contains(where: { $0.url.host() == "openrouter.ai" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        await container.hubs.syncDue(maxAge: 0)
        await container.dataStore.refreshAll(force: true)

        XCTAssertTrue(http.requests.contains { $0.url.host() == "openrouter.ai" }, "the direct account still refreshes")
        XCTAssertEqual(Set(http.requests.compactMap { $0.url.host() }), ["openrouter.ai"], "nothing goes to a hub or through a tunnel")
    }
}
