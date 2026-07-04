import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountStoreTests: XCTestCase {
    func testDefaultAccountExistsWithoutCredentials() {
        let store = CodexAccountStore(
            defaults: isolatedDefaults(),
            keychain: ServiceKeychain(),
            environment: FakeEnvironment([:]),
            files: FakeFiles()
        )

        let contexts = store.accountContexts()

        XCTAssertEqual(contexts.map(\.record.providerID), ["codex"])
        XCTAssertEqual(contexts.first?.record.displayName, "Codex")
    }

    func testManagedAccountUsesLegacyCodexProviderIDWhenFirst() throws {
        let keychain = ServiceKeychain()
        let store = CodexAccountStore(
            defaults: isolatedDefaults(),
            keychain: keychain,
            environment: FakeEnvironment([:]),
            files: FakeFiles()
        )
        _ = try store.saveManagedAuth(auth(accountID: "acct_1"))

        let records = store.visibleRecords()

        XCTAssertEqual(records.map(\.providerID), ["codex"])
        XCTAssertEqual(records.map(\.source), [.managed])
        XCTAssertFalse(keychain.values.isEmpty)
    }

    func testDuplicateManagedLoginRefreshesExistingAccount() throws {
        let store = CodexAccountStore(
            defaults: isolatedDefaults(),
            keychain: ServiceKeychain(),
            environment: FakeEnvironment([:]),
            files: FakeFiles()
        )
        _ = try store.saveManagedAuth(auth(access: "first", accountID: "acct_1"))
        store.rename(store.visibleRecords()[0], to: "Work")
        _ = try store.saveManagedAuth(auth(access: "second", accountID: "acct_1"))

        let records = store.visibleRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].displayName, "Work")
    }

    func testManagedAccountWinsOverMatchingCLIAccount() throws {
        let files = FakeFiles([
            "/tmp/codex/auth.json": #"{"tokens":{"access_token":"cli","account_id":"acct_1"}}"#
        ])
        let store = CodexAccountStore(
            defaults: isolatedDefaults(),
            keychain: ServiceKeychain(),
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex"]),
            files: files
        )
        _ = try store.saveManagedAuth(auth(accountID: "acct_1"))

        let records = store.visibleRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].source, .managed)
    }

    func testExtraAccountGetsStablePrefixedProviderID() throws {
        let files = FakeFiles([
            "/tmp/codex/auth.json": #"{"tokens":{"access_token":"cli","account_id":"acct_cli"}}"#
        ])
        let store = CodexAccountStore(
            defaults: isolatedDefaults(),
            keychain: ServiceKeychain(),
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex"]),
            files: files
        )
        _ = try store.saveManagedAuth(auth(accountID: "acct_managed"))

        let records = store.visibleRecords()

        XCTAssertEqual(records[0].providerID, "codex")
        XCTAssertEqual(records[0].source, .cliFile)
        XCTAssertTrue(records[1].providerID.hasPrefix("codex."))
        XCTAssertEqual(records[1].source, .managed)
    }

    private func auth(access: String = "access", accountID: String) -> CodexAuth {
        CodexAuth(tokens: CodexTokens(accessToken: access, refreshToken: "refresh", idToken: nil, accountID: accountID))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "OpenUsageCodexAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
