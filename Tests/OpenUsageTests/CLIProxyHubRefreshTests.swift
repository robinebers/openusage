import Foundation
import os
import XCTest
@testable import OpenUsage

/// Refresh re-reads every hub before it reads usage and ignores a second press while it runs, and the
/// hub row counts only enabled logins OpenUsage can't mirror.
@MainActor
final class CLIProxyHubRefreshTests: XCTestCase {
    nonisolated private static let hubURL = URL(string: "http://mini.local:8317")!

    /// Entries of `GET /v0/management/auth-files` as CLIProxyAPI v8.0.63 answered it on Nov 10: two files
    /// that aren't logins, an enabled Muse login, and disabled Kimi and Cursor logins. The emails are
    /// replaced and the counters, timestamps, and file paths left out.
    nonisolated private static let unsupportedEntries = #"""
    {"auth_index":"3edc842ac8e034cf","disabled":false,"id":"local-models/catalog.json","label":"","name":"local-models/catalog.json","provider":"unknown","runtime_only":false,"source":"file","status":"active","status_message":"","type":"unknown","unavailable":false},
    {"auth_index":"4ca51a96a2f1c5d6","disabled":false,"id":"backups/update-8.0.63.RLlo/catalog.json","label":"","name":"backups/update-8.0.63.RLlo/catalog.json","provider":"unknown","runtime_only":false,"source":"file","status":"active","status_message":"","type":"unknown","unavailable":false},
    {"account":"muse@example.com","account_type":"oauth","auth_index":"e90ea27f261750d3","disabled":false,"email":"muse@example.com","id":"meta-muse_example.com-0bcedfbaf471c6a0.json","label":"muse@example.com","name":"meta-muse_example.com-0bcedfbaf471c6a0.json","provider":"meta","runtime_only":false,"source":"file","status":"active","status_message":"","type":"meta","unavailable":false},
    {"account":"off@example.com","account_type":"oauth","auth_index":"3038d2832263d804","disabled":true,"email":"off@example.com","id":"kimi-off@example.com.json","label":"off@example.com","name":"kimi-off@example.com.json","provider":"kimi","runtime_only":false,"source":"file","status":"disabled","status_message":"","type":"kimi","unavailable":false},
    {"account_type":"oauth","auth_index":"9582d66673ee55f8","disabled":true,"id":"cursor-cbb1d1ac0ce52e35","label":"Cursor","name":"cursor.json","provider":"cursor","quota_provider":"cursor","runtime_only":false,"source":"file","status":"disabled","status_message":"","supports_quota":true,"type":"cursor","unavailable":false}
    """#

    func testRefreshDropsALoginTurnedOffOnTheHubBeforeReadingUsage() async throws {
        let disabled = OSAllocatedUnfairLock(initialState: false)
        let http = RoutingHTTPClient { _ in .json(Self.listing(Self.claude(disabled: disabled.withLock { $0 }))) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: Self.hubURL)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror(try HubLogin.listing(from: Data(Self.listing(Self.claude(disabled: false)).utf8)), from: hub.id)
        XCTAssertEqual(store.accounts(onHub: hub.id).count, 1)
        let container = AppContainer.forTesting(accounts: store, defaults: isolatedDefaults(), http: http)
        await container.hubs.syncDue(maxAge: 0)

        disabled.withLock { $0 = true }
        let before = http.requests.count
        await container.refreshNow()

        XCTAssertTrue(store.accounts(onHub: hub.id).isEmpty, "the login turned off on the hub is gone after Refresh")
        let paths = http.requests.dropFirst(before).map { $0.url.path() }
        XCTAssertEqual(paths, ["/v0/management/auth-files"], "Refresh read the hub's list and sent no usage read for the gone login")
    }

    func testARefreshPressedWhileOneRunsSendsNoSecondUsageRead() async throws {
        let http = RoutingHTTPClient { request in
            if request.url.path() == "/v0/management/auth-files" { try await Task.sleep(for: .milliseconds(200)) }
            return .json(Self.listing(Self.claude(disabled: false)))
        }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: Self.hubURL)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror(try HubLogin.listing(from: Data(Self.listing(Self.claude(disabled: false)).utf8)), from: hub.id)
        let container = AppContainer.forTesting(accounts: store, defaults: isolatedDefaults(), http: http)

        async let first: Void = container.refreshNow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(container.isRefreshingNow, "the footer shows Updating… while the hub is read")
        await container.refreshNow()
        await first

        let usageReads = http.requests.filter { request in
            let call = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            return call?["url"] as? String == ClaudeUsageClient.usageURL.absoluteString
        }
        XCTAssertEqual(usageReads.count, 1, "the second press joined nothing and read nothing")
        XCTAssertFalse(container.isRefreshingNow)
    }

    func testALoginDeletedOnTheHubLeavesAtTheNextRead() async throws {
        let codex = Self.codex
        let body = OSAllocatedUnfairLock(initialState: Self.listing(Self.claude(disabled: false), codex))
        let http = RoutingHTTPClient { _ in .json(body.withLock { $0 }) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()), isEnabled: true)
        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")
        let hub = try XCTUnwrap(store.hubs.first)
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.claude, .codex])

        body.withLock { $0 = String($0.prefix(60)) }
        await sync.syncDue(maxAge: 0)
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.claude, .codex], "a cut-short answer removes nothing")
        guard case .failed = sync.status(of: hub.id) else { return XCTFail("a cut-short answer is a failed read") }

        body.withLock { $0 = Self.listing(codex) }
        await sync.syncDue(maxAge: 0)
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.codex], "the login deleted on the hub is gone after one read")
    }

    /// Robin's dev build, Nov 13: the launch listing found no network because macOS hadn't let OpenUsage onto
    /// the local network yet, and nothing read the hub again, so a login deleted on it kept its card.
    func testAListingThatFoundNoNetworkIsTriedAgainAndDropsTheDeletedLogin() async throws {
        let offline = TestSwitch(false)
        let body = OSAllocatedUnfairLock(initialState: Self.listing(Self.claude(disabled: false), Self.codex))
        let http = RoutingHTTPClient { _ in
            if offline.value { offline.value = false; throw URLError(.notConnectedToInternet) }
            return .json(body.withLock { $0 })
        }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()), isEnabled: true)
        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")
        let hub = try XCTUnwrap(store.hubs.first)

        offline.value = true
        body.withLock { $0 = Self.listing(Self.codex) }
        await sync.syncDue(maxAge: 0)

        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.codex], "the listing was tried again and the deleted login left")
        XCTAssertEqual(sync.status(of: hub.id), .synced(unsupported: 0))
    }

    func testAFailedListingIsReadAgainAtTheNextPass() async throws {
        let failing = TestSwitch(false)
        let body = OSAllocatedUnfairLock(initialState: Self.listing(Self.claude(disabled: false), Self.codex))
        let http = RoutingHTTPClient { _ in failing.value ? .json("{}", status: 500) : .json(body.withLock { $0 }) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()), isEnabled: true)
        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")
        let hub = try XCTUnwrap(store.hubs.first)

        failing.value = true
        await sync.syncDue(maxAge: 0)
        guard case .failed = sync.status(of: hub.id) else { return XCTFail("the hub answered with an error") }

        failing.value = false
        body.withLock { $0 = Self.listing(Self.codex) }
        await sync.syncDue()
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.codex], "the next pass read the hub again, not an hour later")
    }

    /// Robin's dev build, Nov 13: two cards whose logins were deleted on the hub got "auth credential not
    /// found" from every usage read while the app's last listing still had them.
    func testACardTheHubSaysHasNoLoginLeavesWhenTheHubIsListedAgain() async throws {
        let http = RoutingHTTPClient { request in
            request.url.path() == "/v0/management/auth-files"
                ? .json(Self.listing(Self.codex))
                : .json(#"{"error":"auth credential not found for auth_index"}"#, status: 400)
        }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: Self.hubURL)
        try store.addHub(hub, key: "mgmt-key")
        try store.mirror(try HubLogin.listing(from: Data(Self.listing(Self.claude(disabled: false), Self.codex).utf8)), from: hub.id)
        let container = AppContainer.forTesting(accounts: store, defaults: isolatedDefaults(), http: http)
        let claude = try XCTUnwrap(store.accounts(onHub: hub.id).first { $0.kind == .claude })

        _ = await container.dataStore.refresh(providerID: claude.cardID, force: true)

        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.codex], "the hub was listed again and the card left")
    }

    func testTheHubCountsOnlyEnabledLoginsOpenUsageCantMirror() async throws {
        let http = RoutingHTTPClient { _ in .json(Self.listing(Self.claude(disabled: false), Self.unsupportedEntries)) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()), isEnabled: true)

        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")

        let hub = try XCTUnwrap(store.hubs.first)
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.claude])
        XCTAssertEqual(sync.status(of: hub.id), .synced(unsupported: 1), "only the enabled Muse login counts; disabled logins and the hub's own files don't")
    }

    // MARK: - Listing

    nonisolated private static func claude(disabled: Bool) -> String {
        #"{"account":"alice@example.com","account_type":"oauth","auth_index":"b799da203df01af5","disabled":\#(disabled),"email":"alice@example.com","id":"claude-alice@example.com.json","label":"alice@example.com","name":"claude-alice@example.com.json","provider":"claude","status":"active","type":"claude"}"#
    }

    nonisolated private static let codex = #"{"account_type":"oauth","auth_index":"5c0b1f2e9a7d3c41","email":"bob@example.com","id":"codex-bob@example.com.json","provider":"codex","type":"codex"}"#

    nonisolated private static func listing(_ entries: String...) -> String {
        #"{"files":["# + entries.joined(separator: ",") + "]}"
    }
}
