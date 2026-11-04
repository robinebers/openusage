import Foundation
import XCTest
@testable import OpenUsage

/// What keeps a hub's management key and its mirrored accounts safe from forged preferences, plain http,
/// a short listing, and a failing Keychain.
@MainActor
final class CLIProxyHubHardeningTests: XCTestCase {
    private let hubURL = URL(string: "http://mini.local:8317")!
    private let gate = CLIProxyHubGate()

    func testAKeyGoesOnlyToTheAddressItWasSavedFor() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let hubKeys = InMemoryHubKeyVault()
        let hub = CLIProxyHub(url: hubURL)
        let store = AccountStore(defaults: defaults, vault: vault, hubKeys: hubKeys)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror([Self.login("a", "claude")], from: hub.id)
        let forgedHub = CLIProxyHub(id: hub.id, url: URL(string: "https://attacker.example")!, addedAt: hub.addedAt)
        var account = store.accounts[0]
        account.hub = HubLink(hub: forgedHub, login: Self.login("a", "claude"))
        defaults.set(try JSONEncoder().encode([forgedHub]), forKey: AccountStore.hubsStorageKey)
        defaults.set(try JSONEncoder().encode([account]), forKey: AccountStore.storageKey)

        let rewritten = AccountStore(defaults: defaults, vault: vault, hubKeys: hubKeys)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"files":[]}"#.utf8)) }
        let sync = CLIProxyHubSync(accounts: rewritten, client: CLIProxyHubClient(http: http, gate: gate), isEnabled: true)
        await sync.syncDue(maxAge: 0)
        let runtimes = ProviderCatalog.make(accounts: rewritten.accounts, vault: vault, hubKeys: hubKeys, http: http, hubsEnabled: true)
        let failure = await runtimes[0].refresh().failure

        XCTAssertTrue(http.requests.isEmpty, "the key never goes to a rewritten address")
        let message = "The CLIProxyAPI hub at attacker.example isn’t the address its management key was saved for. Remove the hub and connect it again."
        XCTAssertEqual(sync.status(of: hub.id), .failed(message))
        XCTAssertEqual(failure?.message, message)
    }

    func testTheKeyGoesOverHttpOnlyWhenTypedAndOnlyToThisMacOrTheLocalNetwork() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"files":[]}"#.utf8)) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate), isEnabled: true)

        do {
            try await sync.connect(url: "http://hub.example.com:8317", key: "mgmt-key")
            XCTFail("plain http to a public name is refused")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Use https for hub.example.com:8317. OpenUsage uses http only for a hub on this Mac, your local network, or Tailscale."
            )
        }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(store.hubs.isEmpty)

        try await sync.connect(url: "hub.example.com:8317", key: "mgmt-key")
        try await sync.connect(url: "http://192.168.1.20:8317", key: "mgmt-key")
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://hub.example.com:8317/v0/management/auth-files", "http://192.168.1.20:8317/v0/management/auth-files"
        ], "no scheme means https")

        let allowed = ["http://127.0.0.1:8317", "http://localhost:8317", "http://10.0.0.5", "http://172.20.1.1", "http://169.254.1.1",
                       "http://mini.local:8317", "http://[::1]:8317", "https://hub.example.com"]
        let refused = ["http://hub.example.com", "http://10.0.0.1.attacker.example", "http://172.32.0.1",
                       "http://8.8.8.8", "ftp://mini.local"]
        for url in allowed { XCTAssertTrue(CLIProxyHub.allowsKey(at: URL(string: url)!), url) }
        for url in refused { XCTAssertFalse(CLIProxyHub.allowsKey(at: URL(string: url)!), url) }
    }

    func testTailscaleHostsGetTheKeyOverHttp() {
        let allowed = ["http://mini.tail2a0317.ts.net:8317", "http://MINI.TAIL2A0317.TS.NET", "http://100.64.0.0", "http://100.100.20.5:8317",
                       "http://100.127.255.255", "http://[fd7a:115c:a1e0::1]:8317", "http://[fd7a:115c:a1e0:ab12::5]"]
        let refused = ["http://100.63.255.255", "http://100.128.0.0", "http://ts.net", "http://evilts.net", "http://mini.ts.net.attacker.example",
                       "http://[2001:db8::1]:8317", "http://100.64.0.1.attacker.example"]
        for url in allowed { XCTAssertTrue(CLIProxyHub.allowsKey(at: URL(string: url)!), url) }
        for url in refused { XCTAssertFalse(CLIProxyHub.allowsKey(at: URL(string: url)!), url) }
    }

    func testAnHttpsHubThatAnswersOnlyOverHttpSaysToUseHttp() async throws {
        let http = RoutingHTTPClient { request in
            guard request.url.scheme == "http" else { throw URLError(.secureConnectionFailed) }
            let status = request.url.host() == "10.0.0.9" ? 400 : 200
            return HTTPResponse(statusCode: status, headers: [:], body: Data("CLIProxyAPI Server".utf8))
        }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate), isEnabled: true)

        for (input, message) in [
            ("https://10.0.0.9:8317", "Can’t reach the CLIProxyAPI hub at 10.0.0.9:8317."),
            ("mini.tail2a0317.ts.net:8317", "This hub doesn’t use https. Try http://mini.tail2a0317.ts.net:8317."),
            ("https://192.168.1.20:8317", "This hub doesn’t use https. Try http://192.168.1.20:8317."),
            ("https://hub.example.com:8317", "Can’t reach the CLIProxyAPI hub at hub.example.com:8317."),
        ] {
            do {
                try await sync.connect(url: input, key: "mgmt-key")
                XCTFail("\(input) connected")
            } catch {
                XCTAssertEqual(error.localizedDescription, message)
            }
        }

        let checks = http.requests.filter { $0.url.scheme == "http" }
        XCTAssertEqual(
            checks.map(\.url.absoluteString), ["http://10.0.0.9:8317", "http://mini.tail2a0317.ts.net:8317", "http://192.168.1.20:8317"],
            "a public host gets no http request"
        )
        XCTAssertTrue(checks.allSatisfy { $0.headers.isEmpty }, "the http check carries no key")
        XCTAssertTrue(store.hubs.isEmpty)
    }

    func testAListingThatLacksLoginsKeepsTheirAccountsUntilTheNextListingAgrees() throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: hubURL)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror([Self.login("a", "claude"), Self.login("b", "codex")], from: hub.id)
        let mirrored = store.accounts

        try store.mirror(HubLogin.listing(from: Data(#"{"files":[]}"#.utf8)), from: hub.id)
        XCTAssertEqual(store.accounts, mirrored, "one empty listing, as from a hub mid-restart, erases nothing")
        try store.mirror([Self.login("a", "claude"), Self.login("b", "codex")], from: hub.id)
        let uncallable = #"{"files":[{"id":"a","provider":"claude"},{"id":"b","auth_index":"index-b","provider":"codex"}]}"#
        try store.mirror(HubLogin.listing(from: Data(uncallable.utf8)), from: hub.id)
        XCTAssertEqual(store.accounts, mirrored, "a login listed without an auth index keeps its account")

        try store.mirror([Self.login("a", "claude")], from: hub.id)
        XCTAssertEqual(store.accounts, mirrored, "a login missing from one listing stays")
        try store.mirror([Self.login("a", "claude")], from: hub.id)
        XCTAssertEqual(store.accounts.map(\.id), [mirrored[0].id], "a login two listings in a row lack is removed")
    }

    func testAFailedKeychainWriteLeavesTheHubUnreadSoTheNextSyncRetries() async throws {
        let vault = FailingVault()
        vault.saveError.value = CredentialVaultError.missingCredential
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault, hubKeys: InMemoryHubKeyVault())
        let listing = #"{"files":[{"id":"a","auth_index":"index-a","provider":"claude","account_type":"oauth"}]}"#
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(listing.utf8)) }
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate), isEnabled: true)

        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")
        let hub = try XCTUnwrap(store.hubs.first)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(
            sync.status(of: hub.id), .failed("OpenUsage couldn’t save this hub’s logins in the Keychain. It tries again when Accounts opens.")
        )

        vault.saveError.value = nil
        await sync.syncDue()
        XCTAssertEqual(http.requests.count, 2, "the hub is read again at the next sync, not an hour later")
        XCTAssertEqual(store.accounts.map(\.hub?.loginID), ["a"])
        XCTAssertEqual(sync.status(of: hub.id), .synced(unsupported: 0))
    }

    func testAFailedRemovalIsTriedAgainAtTheNextRead() throws {
        let vault = FailingVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault, hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: hubURL)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror([Self.login("a", "claude")], from: hub.id)
        try store.mirror([], from: hub.id)

        vault.deleteError.value = CredentialVaultError.missingCredential
        XCTAssertThrowsError(try store.mirror([], from: hub.id))
        XCTAssertEqual(store.accounts.count, 1)
        vault.deleteError.value = nil
        try store.mirror([], from: hub.id)

        XCTAssertTrue(store.accounts.isEmpty, "the login two listings lacked is removed once the Keychain lets it go")
    }

    private static func login(_ id: String, _ provider: String) -> HubLogin {
        HubLogin(id: id, authIndex: "index-\(id)", provider: provider, label: id, isOAuth: true, isDisabled: false, chatGPTAccountID: nil)
    }
}
