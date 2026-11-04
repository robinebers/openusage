import Foundation
import XCTest
@testable import OpenUsage

/// A CLIProxyAPI hub's login list mirrored as accounts: what is read from the listing, and how the
/// mirror follows the hub.
@MainActor
final class CLIProxyHubTests: XCTestCase {
    /// `GET /v0/management/auth-files` as CLIProxyAPI v8.0.47 (90c447d) answered it, with dummy logins and
    /// the per-entry counters, timestamps, and file paths left out.
    nonisolated static let recordedListing = #"""
    {"files":[
    {"account":"alice@example.com","account_type":"oauth","auth_index":"b799da203df01af5","disabled":false,"email":"alice@example.com","id":"claude-alice@example.com.json","label":"alice@example.com","name":"claude-alice@example.com.json","provider":"claude","status":"active","status_message":"","type":"claude","unavailable":false},
    {"account_type":"oauth","auth_index":"b9e9b8780e7ae25b","disabled":false,"id":"claude-apikey-file.json","label":"claude","name":"claude-apikey-file.json","provider":"claude","status":"active","status_message":"","type":"claude","unavailable":false},
    {"account":"disabled@example.com","account_type":"oauth","auth_index":"c62b935696257364","disabled":true,"email":"disabled@example.com","id":"claude-disabled@example.com.json","label":"disabled@example.com","name":"claude-disabled@example.com.json","provider":"claude","status":"disabled","status_message":"","type":"claude","unavailable":false},
    {"account":"notoken@example.com","account_type":"oauth","auth_index":"4af9debc50b6ca56","disabled":false,"email":"notoken@example.com","id":"claude-notoken@example.com.json","label":"notoken@example.com","name":"claude-notoken@example.com.json","provider":"claude","status":"active","status_message":"","type":"claude","unavailable":false},
    {"account":"codex-user@example.com","account_type":"oauth","auth_index":"2eff6fcd14d4e964","disabled":false,"email":"codex-user@example.com","id":"codex-codex-user@example.com-plus.json","id_token":{"chatgpt_account_id":"acct-dummy-0001","plan_type":"plus"},"label":"codex-user@example.com","name":"codex-codex-user@example.com-plus.json","provider":"codex","status":"active","status_message":"","type":"codex","unavailable":false},
    {"account":"kim@example.com","account_type":"oauth","auth_index":"e1c935aa6b063328","disabled":false,"email":"kim@example.com","id":"kimi-kim@example.com.json","label":"kim@example.com","name":"kimi-kim@example.com.json","provider":"kimi","status":"active","status_message":"","type":"kimi","unavailable":false}
    ]}
    """#

    func testEveryHubProviderWithARuntimeIsMirroredAndCursorIsNot() throws {
        let providers = ["antigravity", "devin", "xai", "cursor", "gemini"]
        let body = #"{"files":["# + providers.map { #"{"id":"\#($0)","auth_index":"\#($0)-index","provider":"\#($0)","account_type":"oauth"}"# }
            .joined(separator: ",") + "]}"
        let logins = try HubLogin.listing(from: Data(body.utf8))
        XCTAssertEqual(logins.map(\.kind), [.antigravity, .devin, .grok, nil, nil], "Cursor's hub login holds an API key, not a session")
    }

    func testAnAPIKeyEntryOrAnUncallableEntryIsNotMirrored() throws {
        let body = #"{"files":[{"id":"a","auth_index":"1","provider":"claude","account_type":"api_key"},{"id":"b","provider":"codex"},{"id":"c","auth_index":"3","provider":"codex"}]}"#
        let logins = try HubLogin.listing(from: Data(body.utf8))
        XCTAssertEqual(logins.map(\.kind), [nil, .codex, .codex])
        XCTAssertNil(logins[1].authIndex)
        let (store, _, hub) = try makeHub()
        try store.mirror(logins, from: hub.id)
        XCTAssertEqual(store.accounts.map(\.hub?.loginID), ["c"], "an entry without an auth index can't be called")
        XCTAssertThrowsError(try HubLogin.listing(from: Data("<html>".utf8)))
    }

    func testAddAccountOffersTheHubLast() {
        XCTAssertEqual(AddAccountChoice.all, ProviderKind.allCases.map(AddAccountChoice.provider) + [.cliproxyHub])
    }

    func testTheHubAddressIsCleanedFromWhatTheUserPastes() {
        let cases: [(String, String?)] = [
            ("127.0.0.1:8317", "https://127.0.0.1:8317"),
            ("hub.example.com", "https://hub.example.com"),
            (" http://mini.local:8317/ ", "http://mini.local:8317"),
            ("http://192.168.1.20:8317/management.html#/usage", "http://192.168.1.20:8317"),
            ("https://hub.example.com/v0/management?x=1", "https://hub.example.com"),
            ("https://hub.example.com/cpa/v1", "https://hub.example.com/cpa"),
            ("ftp://hub", nil),
            ("", nil)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CLIProxyHub.baseURL(from: input)?.absoluteString, expected, input)
        }
        XCTAssertEqual(CLIProxyHub.host(of: URL(string: "http://mini.local:8317")!), "mini.local:8317")
    }

    func testConnectingMirrorsEverySupportedLoginAsAnOrdinaryAccount() throws {
        let (store, vault, hub) = try makeHub()
        try store.mirror(try HubLogin.listing(from: Data(Self.recordedListing.utf8)), from: hub.id)

        XCTAssertEqual(store.accounts.map(\.kind), [.claude, .claude, .claude, .codex])
        XCTAssertEqual(
            store.accounts.map(\.label), ["alice@example.com", "Claude Account", "notoken@example.com", "codex-user@example.com"],
            "hub order is kept, a login disabled on the hub gets no account, and one without an email gets the default name"
        )
        XCTAssertEqual(store.accounts.first?.hub?.authIndex, "b799da203df01af5")
        XCTAssertTrue(store.accounts.allSatisfy { $0.hub?.hubID == hub.id && $0.hub?.hubURL == hub.url })
        let codex = try XCTUnwrap(store.accounts.first { $0.kind == .codex })
        XCTAssertEqual(
            try vault.load(codex.id),
            .oauth(OAuthTokens(accessToken: "$TOKEN$", extras: ["chatgpt_account_id": "acct-dummy-0001"])),
            "the hub's token never reaches the Mac, and nothing is there to refresh"
        )
        XCTAssertEqual(try store.hubKeys.load(hub.id), HubKey(key: "mgmt-key", url: hub.url))
        XCTAssertNil(try vault.load(hub.id), "the management key isn't kept with the accounts' sign-ins")
    }

    func testMirroringTheSameListingTwiceChangesNothing() throws {
        let (store, vault, hub) = try makeHub()
        let logins = try HubLogin.listing(from: Data(Self.recordedListing.utf8))
        try store.mirror(logins, from: hub.id)
        let accounts = store.accounts
        let credentials = try accounts.map { try vault.load($0.id) }
        var changes = 0
        store.didChange = { changes += 1 }

        try store.mirror(logins, from: hub.id)
        try store.mirror(logins, from: hub.id)

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.accounts, accounts)
        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, credentials)
    }

    func testTheMirrorFollowsLoginsAddedRemovedRenamedAndDisabledOnTheHub() throws {
        let (store, vault, hub) = try makeHub()
        store.add(kind: .claude, label: "Direct", credential: .oauth(OAuthTokens(accessToken: "direct")))
        try store.mirror([login("a", "claude"), login("b", "codex"), login("c", "claude")], from: hub.id)
        let a = try XCTUnwrap(store.accounts.first { $0.hub?.loginID == "a" })
        let b = try XCTUnwrap(store.accounts.first { $0.hub?.loginID == "b" })
        let c = try XCTUnwrap(store.accounts.first { $0.hub?.loginID == "c" })
        store.rename(c.id, to: "Renamed Here")

        let next = [login("b", "codex", index: "moved"), login("c", "claude", disabled: true), login("d", "claude")]
        try store.mirror(next, from: hub.id)
        XCTAssertEqual(store.accounts.map(\.label), ["Direct", "a", "b", "d"], "a disabled login disappears and a new one is added last")
        try store.mirror(next, from: hub.id)

        XCTAssertEqual(store.accounts.map(\.label), ["Direct", "b", "d"], "a login two listings lack disappears")
        XCTAssertEqual(store.accounts.first { $0.id == b.id }?.hub?.authIndex, "moved", "a renamed hub file is relinked, not re-added")
        XCTAssertEqual(try [a, c].map { try vault.load($0.id) }, [nil, nil], "the gone and disabled logins' credentials are deleted")

        try store.mirror([login("b", "codex", index: "moved"), login("c", "claude"), login("d", "claude")], from: hub.id)
        XCTAssertEqual(store.accounts.map(\.label), ["Direct", "b", "d", "c"], "a login enabled again comes back as a new account, last")
        XCTAssertNotEqual(store.accounts.last?.id, c.id)
    }

    func testRemovingTheHubRemovesItsAccountsAndKeyOnly() throws {
        let (store, vault, hub) = try makeHub()
        let direct = store.add(kind: .codex, label: "Direct", credential: .oauth(OAuthTokens(accessToken: "direct")))
        try store.mirror([login("a", "claude"), login("b", "codex")], from: hub.id)
        let mirrored = store.accounts(onHub: hub.id)
        XCTAssertEqual(mirrored.count, 2)

        store.removeHub(hub.id)

        XCTAssertEqual(store.accounts.map(\.id), [direct.id])
        XCTAssertTrue(store.hubs.isEmpty)
        XCTAssertEqual(try (mirrored + [direct]).map { try vault.load($0.id) }, [nil, nil, .oauth(OAuthTokens(accessToken: "direct"))])
        XCTAssertNil(try store.hubKeys.load(hub.id))
        XCTAssertTrue(AccountStore(defaults: defaults, vault: vault).hubs.isEmpty, "the removal is saved")
    }

    func testAHubAndItsAccountsSurviveARelaunch() throws {
        let (store, vault, hub) = try makeHub()
        try store.mirror([login("a", "claude")], from: hub.id)

        let relaunched = AccountStore(defaults: defaults, vault: vault)

        XCTAssertEqual(relaunched.hubs, [hub])
        XCTAssertEqual(relaunched.accounts.map(\.hub), store.accounts.map(\.hub))
    }

    func testALoginOnAHubIsNeverADuplicateOfADirectSignIn() throws {
        let (store, vault, hub) = try makeHub()
        try store.mirror([login("a", "claude")], from: hub.id)
        let mirrored = try XCTUnwrap(store.accounts.first)
        try vault.update(.oauth(OAuthTokens(accessToken: "$TOKEN$", extras: [OAuthTokens.identityKey: "acct/org"])), for: mirrored.id)

        let direct = AccountCredential.oauth(OAuthTokens(accessToken: "real", extras: [OAuthTokens.identityKey: "acct/org"]))
        XCTAssertNoThrow(try store.checkForDuplicate(direct, kind: .claude, organization: nil), "the same login signed in directly shows twice")
    }

    private var defaults: UserDefaults!

    private func makeHub() throws -> (AccountStore, InMemoryCredentialVault, CLIProxyHub) {
        let vault = InMemoryCredentialVault()
        defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: vault, hubKeys: InMemoryHubKeyVault())
        let hub = CLIProxyHub(url: URL(string: "http://mini.local:8317")!)
        try store.addHub(hub, key: "mgmt-key")
        return (store, vault, hub)
    }

    private func login(_ id: String, _ provider: String, index: String? = nil, disabled: Bool = false) -> HubLogin {
        HubLogin(
            id: id, authIndex: index ?? "index-\(id)", provider: provider, label: id, isOAuth: true, isDisabled: disabled,
            chatGPTAccountID: provider == "codex" ? "acct-\(id)" : nil
        )
    }
}
