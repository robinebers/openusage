import XCTest
@testable import OpenUsage

@MainActor
final class AccountStoreTests: XCTestCase {
    func testAnAddedOrRenamedAccountAlwaysHasANameTheDashboardShows() {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let blank = store.add(kind: .openrouter, label: "  ", credential: .apiKey("first"))
        let bare = store.add(kind: .zai, label: "z.ai", credential: .apiKey("second"))

        XCTAssertEqual(store.accounts.map(\.label), ["OpenRouter Account", "Z.ai Account"])

        store.rename(blank.id, to: "Work")
        store.rename(bare.id, to: "")
        XCTAssertEqual(store.accounts.map(\.label), ["Work", "Z.ai Account"])
        store.rename(blank.id, to: "OpenRouter")
        XCTAssertEqual(store.accounts.map(\.label), ["OpenRouter Account", "Z.ai Account"])
        XCTAssertEqual(
            store.accounts.map { Provider(id: $0.cardID, kind: $0.kind, accountLabel: $0.label).labelBesideName },
            ["OpenRouter Account", "Z.ai Account"]
        )
    }

    func testAStoredAccountWithoutANameTheDashboardShowsIsNamedOnLoad() throws {
        let defaults = isolatedDefaults()
        let stored = [
            Account(kind: .openrouter, label: "", addedAt: Date(timeIntervalSince1970: 1)),
            Account(kind: .openrouter, label: "OpenRouter", addedAt: Date(timeIntervalSince1970: 2)),
            Account(kind: .claude, label: "Work", addedAt: Date(timeIntervalSince1970: 3))
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: AccountStore.storageKey)

        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())

        XCTAssertEqual(store.accounts.map(\.id), stored.map(\.id))
        XCTAssertEqual(store.accounts.map(\.label), ["OpenRouter Account", "OpenRouter Account", "Work"])
        let saved = try JSONDecoder().decode([Account].self, from: XCTUnwrap(defaults.data(forKey: AccountStore.storageKey)))
        XCTAssertEqual(saved.map(\.label), ["OpenRouter Account", "OpenRouter Account", "Work"], "the names are saved")
    }

    func testANewAccountNeverTakesTheCardIDOfOneAlreadyAdded() throws {
        var ids = [
            "1A2B3C4D-0000-4000-8000-000000000001", "1A2B3C4D-0000-4000-8000-000000000002",
            "5E6F7A8B-0000-4000-8000-000000000003", "1A2B3C4D-0000-4000-8000-000000000004",
            "9C0D1E2F-0000-4000-8000-000000000005"
        ].compactMap(UUID.init(uuidString:))
        let store = AccountStore(
            defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault(), makeID: { ids.removeFirst() }
        )
        let hub = CLIProxyHub(url: URL(string: "http://mini.local:8317")!)
        try store.addHub(hub, key: "mgmt-key")

        store.add(kind: .claude, label: "Work", credential: .apiKey("work"))
        store.add(kind: .claude, label: "Home", credential: .apiKey("home"))
        try store.mirror([
            HubLogin(id: "a", authIndex: "index-a", provider: "claude", label: "Hub", isOAuth: true, isDisabled: false, chatGPTAccountID: nil)
        ], from: hub.id)

        XCTAssertEqual(
            store.accounts.map(\.cardID), ["claude@1a2b3c4d", "claude@5e6f7a8b", "claude@9c0d1e2f"],
            "an id whose first 8 hex digits an added account of the kind already has is drawn again"
        )
    }

    func testAnEntryThisBuildCannotReadStaysStoredThroughAddRenameAndRemove() throws {
        let defaults = isolatedDefaults()
        defaults.set(StoredAccountList.data, forKey: AccountStore.storageKey)
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let futureEntry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StoredAccountList.futureEntry.utf8)) as? NSDictionary)
        func storedList() throws -> NSArray {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: AccountStore.storageKey))) as? NSArray)
        }

        XCTAssertEqual(store.accounts, [StoredAccountList.claude])
        let added = store.add(kind: .codex, label: "Home", credential: .apiKey("key"))
        XCTAssertTrue(try storedList().contains(futureEntry), "kept through an add")
        store.rename(StoredAccountList.claude.id, to: "Renamed")
        XCTAssertTrue(try storedList().contains(futureEntry), "kept through a rename")
        store.remove(added.id)
        XCTAssertTrue(try storedList().contains(futureEntry), "kept through a remove")

        XCTAssertEqual(try storedList().count, 2, "the renamed account and the kept entry")
        XCTAssertEqual(AccountStore(defaults: defaults, vault: InMemoryCredentialVault()).accounts.map(\.label), ["Renamed"])
    }
}
