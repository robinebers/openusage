import Foundation
import XCTest
@testable import OpenUsage

/// With hubs on, a forged hub record that reuses a direct account's id, and a forged hub link, send
/// nothing from the real container: the account's key is never read as the hub's management key.
@MainActor
final class CLIProxyHubForgedRecordTests: XCTestCase {
    func testAForgedHubAndHubLinkSendNothingFromTheContainer() async throws {
        XCTAssertTrue(CLIProxyHub.isEnabled)
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
        let accounts = AccountStore(defaults: defaults, vault: vault, hubKeys: InMemoryHubKeyVault())
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)

        container.startRefreshing()
        for _ in 0..<400 where !http.requests.contains(where: { $0.url.host() == "openrouter.ai" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        await container.hubs.syncDue(maxAge: 0)
        await container.dataStore.refreshAll(force: true)

        XCTAssertTrue(http.requests.contains { $0.url.host() == "openrouter.ai" }, "the direct account still refreshes")
        XCTAssertEqual(Set(http.requests.compactMap { $0.url.host() }), ["openrouter.ai"], "nothing goes to a hub or through a tunnel")
        XCTAssertEqual(
            container.hubs.status(of: forgedHub.id),
            .failed("The management key for the CLIProxyAPI hub at attacker.example is missing. Replace it in Accounts.")
        )
        accounts.removeHub(forgedHub.id)
        XCTAssertEqual(try vault.load(direct.id), .apiKey("sk-or-direct-secret"), "removing the hub leaves the account's sign-in")
        XCTAssertEqual(accounts.accounts.map(\.id), [direct.id])
    }
}
