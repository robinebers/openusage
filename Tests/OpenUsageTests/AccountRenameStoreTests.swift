import os
import XCTest
@testable import OpenUsage

@MainActor
final class AccountRenameStoreTests: XCTestCase {
    func testBeginSeedsTheDraftWithTheCurrentName() {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))

        renaming.begin(account.cardID)

        XCTAssertEqual(renaming.edit?.providerID, account.cardID)
        XCTAssertEqual(renaming.draft, "AM1")
    }

    func testCommitSavesTheTrimmedDraft() {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))

        renaming.begin(account.cardID)
        renaming.draft = "  Personal \n"
        renaming.commit()

        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "Personal")
        XCTAssertNil(renaming.edit)
    }

    func testCommittingAnEmptyDraftKeepsTheName() {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .codex, label: "rob@sunstory.com", credential: .apiKey("key"))

        renaming.begin(account.cardID)
        renaming.draft = " \t "
        renaming.commit()

        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "rob@sunstory.com")
        XCTAssertNil(renaming.edit)
    }

    func testCancelDiscardsTheDraft() {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))

        renaming.begin(account.cardID)
        renaming.draft = "AM2"
        renaming.cancel()
        renaming.commit()

        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "AM1")
        XCTAssertNil(renaming.edit)
    }

    func testAnUnchangedDraftDoesNotTouchTheAccounts() {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))
        renaming.begin(account.cardID)
        renaming.draft = " AM1 "

        let accountsChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = accounts.accounts
        } onChange: {
            accountsChanged.withLock { $0 = true }
        }
        renaming.commit()

        XCTAssertFalse(accountsChanged.withLock { $0 }, "a no-op rename must not make AppContainer re-apply the layout")
    }

    func testBeginningAnotherRenameSavesTheOpenOne() {
        let (accounts, renaming) = makeStores()
        let first = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))
        let second = accounts.add(kind: .claude, label: "AM2", credential: .apiKey("key"))

        renaming.begin(first.cardID)
        renaming.draft = "Work"
        renaming.begin(second.cardID)

        XCTAssertEqual(accounts.account(cardID: first.cardID)?.label, "Work")
        XCTAssertEqual(renaming.edit?.providerID, second.cardID)
        XCTAssertEqual(renaming.draft, "AM2")
    }

    func testAStaleEditCannotCloseTheNextOne() throws {
        let (accounts, renaming) = makeStores()
        let account = accounts.add(kind: .claude, label: "AM1", credential: .apiKey("key"))

        renaming.begin(account.cardID)
        let stale = try XCTUnwrap(renaming.edit)
        renaming.cancel()
        renaming.begin(account.cardID)
        renaming.draft = "AM3"

        renaming.commit(stale)
        renaming.cancel(stale)

        XCTAssertEqual(renaming.edit?.providerID, account.cardID)
        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "AM1")
    }

    func testRenamingAnUnknownAccountDoesNothing() {
        let (_, renaming) = makeStores()

        renaming.begin("claude@missing")

        XCTAssertNil(renaming.edit)
    }

    func testFullNamePairsProviderAndAccountName() {
        XCTAssertEqual(
            Provider(id: "claude@1", kind: .claude, accountLabel: "AM1").fullName,
            "Claude · AM1"
        )
        XCTAssertEqual(
            Provider(id: "claude@2", kind: .claude, accountLabel: "").fullName,
            "Claude"
        )
    }

    private func makeStores() -> (AccountStore, AccountRenameStore) {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        return (accounts, AccountRenameStore(accounts: accounts))
    }
}
