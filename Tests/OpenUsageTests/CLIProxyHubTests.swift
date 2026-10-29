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

    func testTheRecordedListingReadsAsLogins() throws {
        let logins = try HubLogin.listing(from: Data(Self.recordedListing.utf8))

        XCTAssertEqual(logins.map(\.id), [
            "claude-alice@example.com.json", "claude-apikey-file.json", "claude-disabled@example.com.json",
            "claude-notoken@example.com.json", "codex-codex-user@example.com-plus.json", "kimi-kim@example.com.json"
        ], "hub order is kept")
        XCTAssertEqual(logins.map(\.kind), [.claude, .claude, .claude, .claude, .codex, nil])
        XCTAssertEqual(logins.map(\.label), [
            "alice@example.com", "claude", "disabled@example.com", "notoken@example.com", "codex-user@example.com", "kim@example.com"
        ], "a login without an email takes the hub's label")
        XCTAssertEqual(logins.first { $0.isDisabled }?.id, "claude-disabled@example.com.json")
        XCTAssertEqual(logins.first { $0.kind == .codex }?.chatGPTAccountID, "acct-dummy-0001")
        XCTAssertEqual(logins.first?.authIndex, "b799da203df01af5")
    }

    func testAnAPIKeyEntryOrAnUncallableEntryIsNotMirrored() throws {
        let body = #"{"files":[{"id":"a","auth_index":"1","provider":"claude","account_type":"api_key"},{"id":"b","provider":"codex"},{"id":"c","auth_index":"3","provider":"codex"}]}"#
        let logins = try HubLogin.listing(from: Data(body.utf8))
        XCTAssertEqual(logins.map(\.id), ["a", "c"], "an entry without an auth index can't be called")
        XCTAssertEqual(logins.map(\.kind), [nil, .codex])
        XCTAssertThrowsError(try HubLogin.listing(from: Data("<html>".utf8)))
    }

    func testTheHubAddressIsCleanedFromWhatTheUserPastes() {
        let cases: [(String, String?)] = [
            ("127.0.0.1:8317", "http://127.0.0.1:8317"),
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
        store.mirror(try HubLogin.listing(from: Data(Self.recordedListing.utf8)), from: hub.id)

        XCTAssertEqual(store.accounts.map(\.kind), [.claude, .claude, .claude, .claude, .codex])
        XCTAssertEqual(store.accounts.map(\.label).last, "codex-user@example.com")
        XCTAssertTrue(store.accounts.allSatisfy { $0.hub?.hubID == hub.id && $0.hub?.hubURL == hub.url })
        XCTAssertEqual(store.accounts.first { $0.label == "disabled@example.com" }?.hub?.isDisabled, true, "a disabled login stays")
        let codex = try XCTUnwrap(store.accounts.first { $0.kind == .codex })
        XCTAssertEqual(
            try vault.load(codex.id),
            .oauth(OAuthTokens(accessToken: "$TOKEN$", extras: [
                "chatgpt_account_id": "acct-dummy-0001", OAuthTokens.identityKey: "acct-dummy-0001/codex-user@example.com"
            ])),
            "the hub's token never reaches the Mac, and nothing is there to refresh"
        )
        XCTAssertEqual(try vault.load(hub.id), .apiKey("mgmt-key"))
    }

    func testMirroringTheSameListingTwiceChangesNothing() throws {
        let (store, vault, hub) = try makeHub()
        let logins = try HubLogin.listing(from: Data(Self.recordedListing.utf8))
        store.mirror(logins, from: hub.id)
        let accounts = store.accounts
        let credentials = try accounts.map { try vault.load($0.id) }
        var changes = 0
        store.didChange = { changes += 1 }

        store.mirror(logins, from: hub.id)
        store.mirror(logins, from: hub.id)

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.accounts, accounts)
        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, credentials)
    }

    func testTheMirrorFollowsLoginsAddedRemovedRenamedAndDisabledOnTheHub() throws {
        let (store, vault, hub) = try makeHub()
        store.add(kind: .claude, label: "Direct", credential: .oauth(OAuthTokens(accessToken: "direct")))
        store.mirror([login("a", "claude"), login("b", "codex"), login("c", "claude")], from: hub.id)
        let b = try XCTUnwrap(store.accounts.first { $0.hub?.loginID == "b" })
        let c = try XCTUnwrap(store.accounts.first { $0.hub?.loginID == "c" })
        store.rename(c.id, to: "Renamed Here")

        store.mirror([login("b", "codex", index: "moved"), login("c", "claude", disabled: true), login("d", "claude")], from: hub.id)

        XCTAssertEqual(store.accounts.map(\.label), ["Direct", "b", "Renamed Here", "d"], "a gone login disappears and a new one is added last")
        XCTAssertEqual(store.accounts.first { $0.id == b.id }?.hub?.authIndex, "moved", "a renamed hub file is relinked, not re-added")
        XCTAssertEqual(store.accounts.first { $0.id == c.id }?.hub?.isDisabled, true)
        XCTAssertEqual(store.accounts.first { $0.id == c.id }?.label, "Renamed Here", "the local name survives a sync")
        XCTAssertEqual(vault.ids.count, 4 + 1, "the gone login's credential is deleted; the hub key stays")
    }

    func testRemovingTheHubRemovesItsAccountsAndKeyOnlyAndReAddingStartsFresh() throws {
        let (store, vault, hub) = try makeHub()
        let direct = store.add(kind: .codex, label: "Direct", credential: .oauth(OAuthTokens(accessToken: "direct")))
        store.mirror([login("a", "claude"), login("b", "codex")], from: hub.id)
        XCTAssertEqual(store.accounts(onHub: hub.id).count, 2)

        let mirrored = Set(store.accounts(onHub: hub.id).map(\.id))
        store.removeHub(hub.id)

        XCTAssertEqual(store.accounts.map(\.id), [direct.id])
        XCTAssertTrue(store.hubs.isEmpty)
        XCTAssertEqual(vault.ids, [direct.id])
        XCTAssertTrue(AccountStore(defaults: defaults, vault: vault).hubs.isEmpty, "the removal is saved")

        let again = CLIProxyHub(url: hub.url)
        try store.addHub(again, key: "mgmt-key")
        store.mirror([login("a", "claude"), login("b", "codex")], from: again.id)
        XCTAssertTrue(Set(store.accounts(onHub: again.id).map(\.id)).isDisjoint(with: mirrored), "nothing is restored: new accounts, new layout entries")
    }

    func testAHubAndItsAccountsSurviveARelaunch() throws {
        let (store, vault, hub) = try makeHub()
        store.mirror([login("a", "claude")], from: hub.id)

        let relaunched = AccountStore(defaults: defaults, vault: vault)

        XCTAssertEqual(relaunched.hubs, [hub])
        XCTAssertEqual(relaunched.accounts.map(\.hub), store.accounts.map(\.hub))
    }

    func testALoginAlreadySignedInDirectlyGetsNoHubAccountUntilTheDirectOneIsRemoved() throws {
        let (store, vault, hub) = try makeHub()
        let directCredential = AccountCredential.oauth(OAuthTokens(
            accessToken: "real", extras: [OAuthTokens.identityKey: "acct-dummy-0001/codex-user@example.com"]
        ))
        let direct = store.add(kind: .codex, label: "Work", credential: directCredential)
        let listing = try HubLogin.listing(from: Data(Self.recordedListing.utf8))
        XCTAssertEqual(listing.first { $0.kind == .codex }?.identity, "acct-dummy-0001/codex-user@example.com")

        XCTAssertEqual(store.mirror(listing, from: hub.id), 1)
        XCTAssertEqual(store.mirror(listing, from: hub.id), 1, "the same listing again changes nothing")

        XCTAssertEqual(store.accounts.filter { $0.kind == .codex }.map(\.id), [direct.id], "the account that was there first wins")
        XCTAssertEqual(store.accounts.first { $0.id == direct.id }?.label, "Work")
        XCTAssertEqual(try vault.load(direct.id), directCredential)

        store.remove(direct.id)
        XCTAssertEqual(store.mirror(listing, from: hub.id), 0)
        XCTAssertEqual(store.accounts.last?.hub?.loginID, "codex-codex-user@example.com-plus.json", "the hub's copy arrives last, as a new account")
        XCTAssertEqual(try vault.load(try XCTUnwrap(store.accounts.last).id)?.identity, "acct-dummy-0001/codex-user@example.com")
    }

    func testAHubLoginIsTheDuplicateOfADirectSignInToTheSameLogin() throws {
        let (store, _, hub) = try makeHub()
        var codex = login("b", "codex")
        codex.identity = "acct-b/b@example.com"
        store.mirror([codex], from: hub.id)

        let direct = AccountCredential.oauth(OAuthTokens(accessToken: "real", extras: [OAuthTokens.identityKey: "acct-b/b@example.com"]))
        XCTAssertEqual(store.account(kind: .codex, organization: nil, signedInAs: direct)?.hub?.hubID, hub.id)
    }

    private var defaults: UserDefaults!

    private func makeHub() throws -> (AccountStore, RecordingVault, CLIProxyHub) {
        let vault = RecordingVault()
        defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: vault)
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

/// An in-memory vault that can list what it holds.
final class RecordingVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: AccountCredential] = [:]

    var ids: Set<UUID> { lock.withLock { Set(credentials.keys) } }

    func load(_ id: UUID) throws -> AccountCredential? { lock.withLock { credentials[id] } }
    func save(_ credential: AccountCredential, for id: UUID) throws { lock.withLock { credentials[id] = credential } }
    func update(_ credential: AccountCredential, for id: UUID) throws {
        try lock.withLock {
            guard credentials[id] != nil else { throw CredentialVaultError.missingCredential }
            credentials[id] = credential
        }
    }
    func delete(_ id: UUID) throws { lock.withLock { credentials[id] = nil } }
}
