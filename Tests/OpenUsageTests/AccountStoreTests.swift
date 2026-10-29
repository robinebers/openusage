import XCTest
@testable import OpenUsage

@MainActor
final class AccountStoreTests: XCTestCase {
    func testAccountsOfSameKindPersistWithDistinctCardIDs() throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let first = AccountStore(defaults: defaults, vault: vault)
        let accountA = first.add(kind: .claude, label: "a@example.com", credential: .apiKey("first"))
        let accountB = first.add(kind: .claude, label: "b@example.com", credential: .apiKey("second"))

        XCTAssertNotEqual(accountA.cardID, accountB.cardID)
        XCTAssertTrue(accountA.cardID.hasPrefix("claude@"))
        let reloaded = AccountStore(defaults: defaults, vault: vault)
        XCTAssertEqual(reloaded.accounts, [accountA, accountB])
        XCTAssertEqual(try reloaded.credential(for: accountA.id), .apiKey("first"))
        XCTAssertEqual(try reloaded.credential(for: accountB.id), .apiKey("second"))
    }

    func testRemoveDeletesCredential() throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: defaults, vault: vault)
        let account = store.add(kind: .openrouter, label: "Primary", credential: .apiKey("key"))

        store.remove(account.id)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(try vault.load(account.id))
    }

    func testRenamePersists() {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: defaults, vault: vault)
        let account = store.add(kind: .codex, label: "Old", credential: .oauth(OAuthTokens(accessToken: "access")))

        store.rename(account.id, to: "New")

        XCTAssertEqual(AccountStore(defaults: defaults, vault: vault).accounts.first?.label, "New")
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
