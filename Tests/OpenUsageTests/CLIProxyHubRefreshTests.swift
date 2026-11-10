import Foundation
import os
import XCTest
@testable import OpenUsage

/// Refresh re-reads every hub before it reads usage, and the hub row counts only enabled logins
/// OpenUsage can't mirror.
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
        let http = Self.hub(listing: { Self.listing(Self.claude(disabled: disabled.withLock { $0 })) })
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

    func testTheHubCountsOnlyEnabledLoginsOpenUsageCantMirror() async throws {
        let http = Self.hub(listing: { Self.listing(Self.claude(disabled: false), Self.unsupportedEntries) })
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()), isEnabled: true)

        try await sync.connect(url: "http://mini.local:8317", key: "mgmt-key")

        let hub = try XCTUnwrap(store.hubs.first)
        XCTAssertEqual(store.accounts(onHub: hub.id).map(\.kind), [.claude])
        XCTAssertEqual(sync.status(of: hub.id), .synced(unsupported: 1), "only the enabled Muse login counts; disabled logins and the hub's own files don't")
    }

    // MARK: - Fake hub

    nonisolated private static func claude(disabled: Bool) -> String {
        #"{"account":"alice@example.com","account_type":"oauth","auth_index":"b799da203df01af5","disabled":\#(disabled),"email":"alice@example.com","id":"claude-alice@example.com.json","label":"alice@example.com","name":"claude-alice@example.com.json","provider":"claude","status":"active","type":"claude"}"#
    }

    nonisolated private static func listing(_ entries: String...) -> String {
        #"{"files":["# + entries.joined(separator: ",") + "]}"
    }

    /// A hub that checks the management key, lists `listing()`, and answers every `api-call` with `{}`.
    nonisolated private static func hub(listing: @escaping @Sendable () -> String) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer mgmt-key" else { return .json(#"{"error":"invalid management key"}"#, status: 401) }
            switch request.url.path() {
            case "/v0/management/auth-files": return .json(listing())
            case "/v0/management/api-call":
                let envelope: [String: Any] = ["status_code": 200, "header": ["Content-Type": ["application/json"]], "body": "{}"]
                return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: envelope))
            default: return .json("", status: 404)
            }
        }
    }
}
