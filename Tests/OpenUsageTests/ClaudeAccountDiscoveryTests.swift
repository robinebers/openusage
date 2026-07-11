import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeAccountDiscoveryTests: XCTestCase {
    private let home = "/home/test"

    // MARK: - Discovery

    func testConfigDirAndMatchingKeychainCollapseToOneAccount() {
        let files = FakeFiles(["\(home)/.claude-work/.credentials.json": creds("work")])
        let keychain = ServiceKeychain()
        let workService = authStore(files: files, keychain: keychain)
            .keychainServiceCandidates(forConfigDir: "\(home)/.claude-work").first!
        keychain.currentUserValues[workService] = creds("work")

        let extras = discover(files: files, keychain: keychain, entries: [".claude", ".claude-work"])
            .filter { !$0.isDefault }

        XCTAssertEqual(extras.count, 1)
        XCTAssertEqual(extras.first?.configDir, "\(home)/.claude-work")
        XCTAssertEqual(extras.first?.keychainService, workService)
    }

    func testSuffixedKeychainWithNoDirIsKeychainOnlyAccount() {
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials-deadbeef"] = creds("orphan")

        let extras = discover(files: FakeFiles(), keychain: keychain, entries: [".claude"])
            .filter { !$0.isDefault }

        XCTAssertEqual(extras.count, 1)
        XCTAssertNil(extras.first?.configDir)
        XCTAssertEqual(extras.first?.keychainService, "Claude Code-credentials-deadbeef")
    }

    func testDefaultAccountIsNotDuplicated() {
        let files = FakeFiles(["\(home)/.claude/.credentials.json": creds("default")])
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] = creds("default")

        let accounts = discover(files: files, keychain: keychain, entries: [".claude"])

        XCTAssertEqual(accounts.filter(\.isDefault).count, 1)
        XCTAssertTrue(accounts.filter { !$0.isDefault }.isEmpty)
        XCTAssertEqual(accounts.first(where: \.isDefault)?.keychainService, "Claude Code-credentials")
    }

    func testTrailingSlashConfigDirPointingAtDefaultIsNotAnExtraAccount() {
        let files = FakeFiles(["\(home)/.claude/.credentials.json": creds("default")])
        let keychain = ServiceKeychain()

        let accounts = ClaudeAccountDiscovery(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "\(home)/.claude/"]),
            files: files,
            keychain: keychain,
            homeDirectory: { [home] in URL(fileURLWithPath: home) },
            contentsOfDirectory: { _ in [".claude"] }
        ).discover()

        XCTAssertEqual(accounts.filter(\.isDefault).count, 1)
        XCTAssertTrue(accounts.filter { !$0.isDefault }.isEmpty, "trailing-slash CLAUDE_CONFIG_DIR must not clone the default account")
    }

    func testJunkCredentialFileIsNotCountedAsAccount() {
        let files = FakeFiles(["\(home)/.claude-junk/.credentials.json": "not json"])
        let keychain = ServiceKeychain()

        let extras = discover(files: files, keychain: keychain, entries: [".claude", ".claude-junk"])
            .filter { !$0.isDefault }

        XCTAssertTrue(extras.isEmpty, "an unparseable .credentials.json is not a usable account")
    }

    // MARK: - Persistence / reconcile

    func testReconcileCollapsesFileOnlyAndKeychainOnlyRecordsOnceLinked() {
        let store = ClaudeAccountsStore(defaults: freshDefaults())
        let dir = "\(home)/.claude-work"
        let service = "Claude Code-credentials-deadbeef"

        // Two prior runs each saw only one side of the same account.
        let fileOnly = store.reconcile(with: [DiscoveredClaudeAccount(configDir: dir, keychainService: nil, isDefault: false)])
        let fileOnlyID = fileOnly[0].id
        store.reconcile(with: [DiscoveredClaudeAccount(configDir: nil, keychainService: service, isDefault: false)])
        XCTAssertEqual(store.records.count, 2)
        // The rename lives on the newer keychain-only record.
        let keychainOnlyID = store.records.first { $0.id != fileOnlyID }!.id
        store.setCustomName("Work", forID: keychainOnlyID)

        // Discovery now links both sources into one account.
        let merged = store.reconcile(with: [DiscoveredClaudeAccount(configDir: dir, keychainService: service, isDefault: false)])

        XCTAssertEqual(merged.count, 1, "the stranded orphan must be collapsed, not left as a second card")
        XCTAssertEqual(merged[0].id, fileOnlyID, "the older record's UUID survives")
        XCTAssertEqual(merged[0].configDirPath, dir)
        XCTAssertEqual(merged[0].keychainService, service)
        XCTAssertEqual(merged[0].customName, "Work", "a custom name from the collapsed record is preserved")
    }

    func testReconcileKeepsUUIDAndCustomNameAcrossRuns() {
        let store = ClaudeAccountsStore(defaults: freshDefaults())
        let discovered = [DiscoveredClaudeAccount(configDir: "\(home)/.claude-work", keychainService: nil, isDefault: false)]

        let first = store.reconcile(with: discovered)
        XCTAssertEqual(first.count, 1)
        let id = first[0].id
        store.setCustomName("Work", forID: id)

        let second = store.reconcile(with: discovered)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, id, "matched account must keep its UUID")
        XCTAssertEqual(second[0].customName, "Work")
        XCTAssertEqual(second[0].displayName, "Work")
    }

    // MARK: - Account-scoped auth store

    func testScopedAuthStoreReadsOnlyItsOwnSources() {
        let files = FakeFiles([
            "/tmp/acctA/.credentials.json": creds("A"),
            "/tmp/acctB/.credentials.json": creds("B")
        ])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": creds("bare")])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([
                "CLAUDE_CONFIG_DIR": "/tmp/other",
                "CLAUDE_CODE_OAUTH_TOKEN": "env-token"
            ]),
            files: files,
            keychain: keychain,
            account: ClaudeAccountScope(configDir: "/tmp/acctA", keychainService: nil)
        )

        let tokens = store.loadCredentialCandidates().compactMap(\.oauth.accessToken)
        XCTAssertEqual(tokens, ["A"], "scoped store must ignore other dirs, the keychain, and the env token")
    }

    // MARK: - Namespaced descriptors

    func testExtraInstanceDescriptorsAreNamespacedAndSpendFree() {
        let uuid = UUID(uuidString: "3F9A2B1C-0000-0000-0000-000000000000")!
        let record = ClaudeAccountRecord(id: uuid, configDirPath: "/tmp/acctA", keychainService: nil, customName: nil)
        let provider = ClaudeProvider(account: record)

        XCTAssertEqual(provider.provider.id, "claude.3f9a2b1c-0000-0000-0000-000000000000")
        XCTAssertEqual(provider.provider.displayName, "Claude (3f9a2b1c)")
        let ids = provider.widgetDescriptors.map(\.id)
        XCTAssertEqual(ids, [
            "\(provider.provider.id).session",
            "\(provider.provider.id).weekly",
            "\(provider.provider.id).sonnet",
            "\(provider.provider.id).fable",
            "\(provider.provider.id).extra"
        ])
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy { $0.providerID == provider.provider.id })
        XCTAssertFalse(provider.widgetDescriptors.contains { $0.isSpendTile || $0.id.hasSuffix(".trend") })
    }

    /// An extra account's provider id is namespaced (`claude.<uuid>`), but its icon must still resolve to
    /// the shared Claude brand mark — every id-keyed icon/branding lookup (dashboard, Customize, and the
    /// menu-bar strip glyph) reads `provider.icon`, so the extra instance has to carry `.providerMark("claude")`.
    func testExtraInstanceIconResolvesToClaudeBrandMark() {
        let record = ClaudeAccountRecord(id: UUID(), configDirPath: "/tmp/acctA", keychainService: nil, customName: nil)

        XCTAssertEqual(record.makeProvider().icon, .providerMark("claude"))
        XCTAssertEqual(ClaudeProvider(account: record).provider.icon, .providerMark("claude"))
    }

    func testDefaultInstanceKeepsClaudeIDsAndSpendTiles() {
        let provider = ClaudeProvider()
        let ids = provider.widgetDescriptors.map(\.id)
        XCTAssertEqual(provider.provider.id, "claude")
        XCTAssertTrue(ids.contains("claude.session"))
        XCTAssertTrue(ids.contains("claude.trend"))
        XCTAssertTrue(provider.widgetDescriptors.contains { $0.isSpendTile })
    }

    // MARK: - Helpers

    private func authStore(files: FakeFiles, keychain: ServiceKeychain) -> ClaudeAuthStore {
        ClaudeAuthStore(environment: FakeEnvironment(), files: files, keychain: keychain)
    }

    private func discover(files: FakeFiles, keychain: ServiceKeychain, entries: [String]) -> [DiscoveredClaudeAccount] {
        ClaudeAccountDiscovery(
            environment: FakeEnvironment(),
            files: files,
            keychain: keychain,
            homeDirectory: { [home] in URL(fileURLWithPath: home) },
            contentsOfDirectory: { _ in entries }
        ).discover()
    }

    private func creds(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","scopes":["user:profile"]}}"#
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "test.claudeAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
