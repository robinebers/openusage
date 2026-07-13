import XCTest
@testable import OpenUsage

/// Multi-account: the persisted accounts store, both providers' discovery, the account-scoped auth
/// stores, and the data store's selected-account projection.
///
/// Reconcile and scoped-auth coverage adapted from PR #965 by Ryan George (@QuadDepo).
@MainActor
final class ProviderAccountsTests: XCTestCase {
    private let home = "/home/test"

    // MARK: - Accounts store

    func testReconcileKeepsUUIDAndCustomNameAcrossRuns() {
        let store = ProviderAccountsStore(defaults: makeUserDefaults("reconcile-stable"))
        let discovered = [DiscoveredAccount(configDir: "\(home)/.codex-work", keychainService: nil, keychainAccount: nil)]

        let first = store.reconcile(providerID: "codex", discovered: discovered)
        XCTAssertEqual(first.count, 1)
        let id = first[0].id
        store.setCustomName("Work", forID: id)

        let second = store.reconcile(providerID: "codex", discovered: discovered)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, id, "matched account must keep its UUID")
        XCTAssertEqual(second[0].displayName, "Work")
    }

    func testReconcileCollapsesARenamedOrphanOnceDiscoveryLinksTheSources() {
        let store = ProviderAccountsStore(defaults: makeUserDefaults("reconcile-collapse"))
        let dir = "\(home)/.codex-work"
        let account = "cli|deadbeefdeadbeef"

        // One run saw the dir only; the user claimed it with a rename (so it survives pruning).
        let fileOnly = store.reconcile(providerID: "codex", discovered: [
            DiscoveredAccount(configDir: dir, keychainService: nil, keychainAccount: nil)
        ])
        let fileOnlyID = fileOnly[0].id
        store.setCustomName("Work", forID: fileOnlyID)
        // A later run saw only the keychain side (keyring mode deleted auth.json), stranding a
        // second record for the same login beside the renamed one.
        store.reconcile(providerID: "codex", discovered: [
            DiscoveredAccount(configDir: nil, keychainService: CodexAuthStore.keychainService, keychainAccount: account)
        ])
        XCTAssertEqual(store.accounts(for: "codex").count, 2)

        // Discovery now links both sources into one account.
        let merged = store.reconcile(providerID: "codex", discovered: [
            DiscoveredAccount(configDir: dir, keychainService: CodexAuthStore.keychainService, keychainAccount: account)
        ])

        XCTAssertEqual(merged.count, 1, "the stranded orphan must collapse, not stay a second picker entry")
        XCTAssertEqual(merged[0].id, fileOnlyID, "the renamed record's UUID survives")
        XCTAssertEqual(merged[0].configDir, dir)
        XCTAssertEqual(merged[0].keychainAccount, account)
        XCTAssertEqual(merged[0].customName, "Work")
    }

    func testSelectionPersistsAndFallsBackOnRemove() {
        let defaults = makeUserDefaults("selection")
        let store = ProviderAccountsStore(defaults: defaults)
        let record = store.reconcile(providerID: "claude", discovered: [
            DiscoveredAccount(configDir: nil, keychainService: "Claude Code-credentials-deadbeef", keychainAccount: nil)
        ])[0]

        store.select(accountID: record.id, for: "claude")
        XCTAssertEqual(store.selectedAccountKey(for: "claude"), record.accountKey)

        // Selection survives a relaunch (a fresh store over the same defaults).
        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(reloaded.selectedAccountKey(for: "claude"), record.accountKey)

        // Removing the selected account falls the card back to the default account.
        reloaded.remove(id: record.id)
        XCTAssertEqual(reloaded.selectedAccountKey(for: "claude"), "claude")
        XCTAssertTrue(reloaded.accounts(for: "claude").isEmpty)
    }

    func testAccountsAreScopedPerProvider() {
        let store = ProviderAccountsStore(defaults: makeUserDefaults("per-provider"))
        store.reconcile(providerID: "claude", discovered: [
            DiscoveredAccount(configDir: nil, keychainService: "Claude Code-credentials-deadbeef", keychainAccount: nil)
        ])

        XCTAssertEqual(store.accounts(for: "claude").count, 1)
        XCTAssertTrue(store.accounts(for: "codex").isEmpty)
        XCTAssertEqual(store.selectedAccountKey(for: "codex"), "codex")
    }

    func testReconcileCarriesEveryLocatorIntoTheRecord() {
        // Regression: a discovered Desktop organization must land ON the record — a record without
        // its locator builds an empty credential scope and can only ever say "Not logged in".
        let defaults = makeUserDefaults("locators")
        let store = ProviderAccountsStore(defaults: defaults)
        let org = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        let records = store.reconcile(providerID: "claude", discovered: [
            DiscoveredAccount(desktopOrganization: org)
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].desktopOrganization, org)
        XCTAssertEqual(records[0].displayName, "Desktop (bbbbbbbb)")
        // And it round-trips through persistence.
        XCTAssertEqual(
            ProviderAccountsStore(defaults: defaults).accounts(for: "claude").first?.desktopOrganization,
            org
        )
    }

    func testReconcilePrunesUnnamedRecordsButKeepsRenamedOnes() {
        let store = ProviderAccountsStore(defaults: makeUserDefaults("prune"))
        let junk = DiscoveredAccount(configDir: nil, keychainService: "Claude Code-credentials-junk", keychainAccount: nil)
        let real = DiscoveredAccount(configDir: nil, keychainService: "Claude Code-credentials-work", keychainAccount: nil)
        let records = store.reconcile(providerID: "claude", discovered: [junk, real])
        XCTAssertEqual(records.count, 2)
        let realID = records.first { $0.keychainService == "Claude Code-credentials-work" }!.id
        store.setCustomName("Work", forID: realID)
        store.select(accountID: records.first { $0.id != realID }!.id, for: "claude")

        // Next launch: discovery no longer returns either (junk filtered out, work login vanished).
        let after = store.reconcile(providerID: "claude", discovered: [])

        XCTAssertEqual(after.map(\.id), [realID], "the renamed record survives; the unclaimed one is pruned")
        XCTAssertEqual(store.selectedAccountKey(for: "claude"), "claude", "a pruned selection falls back to the default account")
    }

    // MARK: - Claude discovery (keychain-only)

    func testClaudeExtraKeychainServiceIsDiscovered() {
        let keychain = ServiceKeychain(values: [
            "Claude Code-credentials": claudeCreds("default"),
            "Claude Code-credentials-deadbeef": claudeCreds("work")
        ])
        let discovery = ClaudeAccountDiscovery(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain),
            keychain: keychain
        )

        let extras = discovery.discoverExtraAccounts()

        XCTAssertEqual(extras.count, 1)
        XCTAssertEqual(extras.first?.keychainService, "Claude Code-credentials-deadbeef")
        XCTAssertNil(extras.first?.configDir, "Claude discovery is keychain-only by design")
    }

    func testClaudeNeverRotatedOneShotLoginItemsAreNotAccounts() {
        // Agent sandboxes leave one suffixed item per run, written once and never rotated. Only an
        // item whose modification date moved meaningfully past creation is a real second login.
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let keychain = ServiceKeychain(values: [
            "Claude Code-credentials": claudeCreds("default"),
            "Claude Code-credentials-junk1": claudeCreds("sandbox"),
            "Claude Code-credentials-junk2": claudeCreds("sandbox"),
            "Claude Code-credentials-work": claudeCreds("work")
        ])
        keychain.itemDates = [
            "Claude Code-credentials-junk1": (created: created, modified: created),
            "Claude Code-credentials-junk2": (created: created, modified: created.addingTimeInterval(45 * 60)),
            "Claude Code-credentials-work": (created: created, modified: created.addingTimeInterval(9 * 24 * 60 * 60))
        ]

        let extras = ClaudeAccountDiscovery(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain),
            keychain: keychain
        ).discoverExtraAccounts()

        XCTAssertEqual(extras.map(\.keychainService), ["Claude Code-credentials-work"])
    }

    func testClaudeEnvConfigDirServiceBelongsToTheDefaultAccount() {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "\(home)/work-claude"])
        let authStore = ClaudeAuthStore(environment: environment, files: FakeFiles(), keychain: ServiceKeychain())
        // The env-derived hash service is the default account's second candidate.
        let envService = authStore.keychainServiceCandidates()[0]
        let keychain = ServiceKeychain(values: [
            "Claude Code-credentials": claudeCreds("default"),
            envService: claudeCreds("env-dir")
        ])

        let extras = ClaudeAccountDiscovery(
            authStore: ClaudeAuthStore(environment: environment, files: FakeFiles(), keychain: keychain),
            keychain: keychain
        ).discoverExtraAccounts()

        XCTAssertTrue(extras.isEmpty, "the CLAUDE_CONFIG_DIR login is the default account, not an extra")
    }

    // MARK: - Codex discovery (file + keychain)

    func testCodexSiblingDirWithUsableAuthJSONIsDiscovered() {
        let files = FakeFiles(["\(home)/.codex-work/auth.json": codexCreds("work")])
        let extras = codexDiscovery(files: files, keychain: ServiceKeychain(), entries: [".codex", ".codex-work"])
            .discoverExtraAccounts()

        XCTAssertEqual(extras.count, 1)
        XCTAssertEqual(extras.first?.configDir, "\(home)/.codex-work")
        XCTAssertNil(extras.first?.keychainAccount)
    }

    func testCodexDirAndMatchingKeychainItemCollapseToOneAccount() {
        let dir = "\(home)/.codex-work"
        let hashAccount = CodexAuthStore.keychainAccountName(forConfigDir: dir)
        let files = FakeFiles(["\(dir)/auth.json": codexCreds("work")])
        let keychain = ServiceKeychain(accountValues: [
            CodexAuthStore.keychainService: [hashAccount: codexCreds("work")]
        ])

        let extras = codexDiscovery(files: files, keychain: keychain, entries: [".codex", ".codex-work"])
            .discoverExtraAccounts()

        XCTAssertEqual(extras.count, 1, "a dir and its hash-matched keychain item are ONE account")
        XCTAssertEqual(extras.first?.configDir, dir)
        XCTAssertEqual(extras.first?.keychainAccount, hashAccount)
    }

    func testCodexKeychainOnlyLoginStandsAloneAndDefaultHomeIsConsumed() {
        let defaultAccount = CodexAuthStore.keychainAccountName(forConfigDir: "\(home)/.codex")
        let keychain = ServiceKeychain(accountValues: [
            CodexAuthStore.keychainService: [
                defaultAccount: codexCreds("default"),
                "cli|deadbeefdeadbeef": codexCreds("orphan")
            ]
        ])

        let extras = codexDiscovery(files: FakeFiles(), keychain: keychain, entries: [".codex"])
            .discoverExtraAccounts()

        XCTAssertEqual(extras.count, 1)
        XCTAssertNil(extras.first?.configDir)
        XCTAssertEqual(extras.first?.keychainAccount, "cli|deadbeefdeadbeef")
    }

    func testCodexApiKeyOnlyAuthJSONIsNotAnAccount() {
        let files = FakeFiles(["\(home)/.codex-key/auth.json": #"{"OPENAI_API_KEY":"sk-test"}"#])
        let extras = codexDiscovery(files: files, keychain: ServiceKeychain(), entries: [".codex", ".codex-key"])
            .discoverExtraAccounts()

        XCTAssertTrue(extras.isEmpty, "an API-key-only auth.json can't serve the usage API")
    }

    // MARK: - Scoped auth stores

    func testScopedClaudeStoreReadsOnlyItsOwnKeychainService() {
        let keychain = ServiceKeychain(values: [
            "Claude Code-credentials": claudeCreds("default"),
            "Claude Code-credentials-deadbeef": claudeCreds("work")
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(["~/.claude/.credentials.json": claudeCreds("file")]),
            keychain: keychain,
            account: ClaudeAccountScope(configDir: nil, keychainService: "Claude Code-credentials-deadbeef")
        )

        let tokens = store.loadCredentialCandidates().compactMap(\.oauth.accessToken)
        XCTAssertEqual(tokens, ["work"], "scoped store must ignore the default service, the file, and the env token")
    }

    func testScopedCodexStoreReadsOnlyItsOwnSources() {
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "\(home)/.codex"]),
            files: FakeFiles([
                "\(home)/.codex/auth.json": codexCreds("default"),
                "\(home)/.codex-work/auth.json": codexCreds("work")
            ]),
            keychain: ServiceKeychain(),
            account: CodexAccountScope(configDir: "\(home)/.codex-work", keychainAccount: nil)
        )

        XCTAssertEqual(store.authPaths(), ["\(home)/.codex-work/auth.json"])
        let tokens = store.loadAuthCandidates().compactMap { $0.auth.tokens?.accessToken }
        XCTAssertEqual(tokens, ["work"], "scoped store must ignore the env CODEX_HOME and other dirs")
        XCTAssertNil(store.loadKeychainAuth(), "a file-only scope has no keychain source")
    }

    func testCodexDefaultKeychainReadPrefersItsOwnHashAccount() {
        let defaultAccount = CodexAuthStore.keychainAccountName(forConfigDir: "~/.codex")
        let keychain = ServiceKeychain(accountValues: [
            CodexAuthStore.keychainService: [
                "cli|deadbeefdeadbeef": codexCreds("other"),
                defaultAccount: codexCreds("default")
            ]
        ])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain)

        XCTAssertEqual(
            store.loadKeychainAuth()?.auth.tokens?.accessToken, "default",
            "with several logins under the shared service, the default instance must read its own item"
        )
    }

    // MARK: - Data store projection

    func testAccountSelectionSwapsTheProviderCardAndErrors() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .used)
        )
        let defaultRuntime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)]
            )
        )
        let workRuntime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let workKey = "test@work"
        var selectedKey = "test"
        let defaults = makeUserDefaults("selection-projection")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [defaultRuntime],
            accountRuntimes: [
                AccountRuntime(providerID: provider.id, accountKey: provider.id, runtime: defaultRuntime),
                AccountRuntime(providerID: provider.id, accountKey: workKey, runtime: workRuntime)
            ],
            selectedAccountKey: { _ in selectedKey },
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults
        )

        // One provider refresh fetches BOTH accounts; the card shows the selected (default) one.
        await store.refresh(providerID: provider.id)
        XCTAssertEqual(store.data(for: descriptor).used, 10)

        // Switching the picker swaps the card instantly from the already-warm account snapshot.
        selectedKey = workKey
        store.applySelection(providerID: provider.id)
        XCTAssertEqual(store.data(for: descriptor).used, 42)

        // And back.
        selectedKey = provider.id
        store.applySelection(providerID: provider.id)
        XCTAssertEqual(store.data(for: descriptor).used, 10)
    }

    func testProviderErrorFollowsTheSelectedAccount() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let healthy = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)]
            )
        )
        let loggedOut = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
        )
        let workKey = "test@work"
        var selectedKey = provider.id
        let defaults = makeUserDefaults("selection-errors")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [healthy],
            accountRuntimes: [
                AccountRuntime(providerID: provider.id, accountKey: provider.id, runtime: healthy),
                AccountRuntime(providerID: provider.id, accountKey: workKey, runtime: loggedOut)
            ],
            selectedAccountKey: { _ in selectedKey },
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults
        )

        await store.refresh(providerID: provider.id)
        XCTAssertNil(store.errorMessage(for: provider.id), "the healthy selected account shows no error")

        selectedKey = workKey
        store.applySelection(providerID: provider.id)
        XCTAssertEqual(store.errorMessage(for: provider.id), CodexAuthError.notLoggedIn.errorDescription)
    }

    // MARK: - Helpers

    private func codexDiscovery(files: FakeFiles, keychain: ServiceKeychain, entries: [String]) -> CodexAccountDiscovery {
        CodexAccountDiscovery(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: keychain),
            keychain: keychain,
            homeDirectory: { [home] in URL(fileURLWithPath: home) },
            contentsOfDirectory: { _ in entries }
        )
    }

    private func claudeCreds(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","scopes":["user:profile"]}}"#
    }

    private func codexCreds(_ token: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","refresh_token":"r","account_id":"acct"}}"#
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccounts.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
