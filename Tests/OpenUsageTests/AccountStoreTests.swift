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

}
