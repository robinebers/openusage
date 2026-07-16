import XCTest
@testable import OpenUsage

/// Provider-instance (multi-account) coverage: id/record stability, launch-time discovery against a
/// real fixture home, credential-scope isolation, defaults translation, and ordering.
@MainActor
final class ProviderInstancesTests: XCTestCase {
    // MARK: - Instance ids + records

    func testInstanceIDsAreStableAndParseable() {
        let id = ProviderInstanceID.make(baseProviderID: "claude", identityKey: "uuid-work")
        XCTAssertEqual(id, ProviderInstanceID.make(baseProviderID: "claude", identityKey: "uuid-work"))
        XCTAssertTrue(ProviderInstanceID.isInstance(id))
        XCTAssertEqual(ProviderInstanceID.base(of: id), "claude")
        XCTAssertFalse(ProviderInstanceID.isInstance("claude"))
        XCTAssertEqual(ProviderInstanceID.base(of: "claude"), "claude")
    }

    func testReconcileKeepsIDsAndOrdinalsStableAcrossLaunches() {
        let defaults = makeScratchDefaults("Reconcile")
        let store = ProviderInstancesStore(defaults: defaults)

        let work = DiscoveredProviderInstance(
            baseProviderID: "claude", kind: .claudeConfigDir,
            anchorPath: "/Users/x/.claude-work", keychainLiteral: "~/.claude-work",
            identityKey: "uuid-work", identityLabel: "work@example.com"
        )
        let second = DiscoveredProviderInstance(
            baseProviderID: "claude", kind: .claudeConfigDir,
            anchorPath: "/Users/x/.claude-side", keychainLiteral: nil,
            identityKey: "uuid-side", identityLabel: nil
        )

        let first = store.reconcile(with: [work, second])
        XCTAssertEqual(first.map(\.ordinal), [2, 3])

        // Same discovery next launch: nothing changes.
        let relaunch = ProviderInstancesStore(defaults: defaults).reconcile(with: [work, second])
        XCTAssertEqual(relaunch, first)

        // One account vanishes, a new one appears: the survivor keeps its id/ordinal, the vanished
        // record is retained (Phase 1 never removes), the new one takes the next ordinal.
        var moved = work
        moved.anchorPath = "/Users/x/.claude-work-moved"
        let third = DiscoveredProviderInstance(
            baseProviderID: "claude", kind: .claudeConfigDir,
            anchorPath: "/Users/x/.claude-three", keychainLiteral: nil,
            identityKey: "uuid-three", identityLabel: nil
        )
        let next = ProviderInstancesStore(defaults: defaults).reconcile(with: [moved, third])
        XCTAssertEqual(next.count, 3)
        XCTAssertEqual(next[0].id, first[0].id)
        XCTAssertEqual(next[0].ordinal, 2)
        XCTAssertEqual(next[0].anchorPath, "/Users/x/.claude-work-moved")
        XCTAssertEqual(next[1], first[1])
        XCTAssertEqual(next[2].ordinal, 4)
    }

    // MARK: - Discovery

    func testDiscoveryFindsRealHomesAndRejectsLookalikes() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Default logins.
        try write(home, ".claude.json", claudeIdentityJSON(uuid: "uuid-default", email: "me@example.com"))
        try makeDir(home, ".claude/projects")
        try write(home, ".codex/auth.json", codexAuthJSON(accountID: "acct-default"))

        // A real second Claude home (file-backed) and a same-account copy that must fold away.
        try write(home, ".claude-work/.claude.json", claudeIdentityJSON(uuid: "uuid-work", email: "work@example.com"))
        try write(home, ".claude-work/.credentials.json", claudeCredentialsJSON(access: "token-work"))
        try write(home, ".claude-copy/.claude.json", claudeIdentityJSON(uuid: "uuid-default", email: "me@example.com"))
        try write(home, ".claude-copy/.credentials.json", claudeCredentialsJSON(access: "token-copy"))

        // A real second Codex home, plus lookalikes: a pi-style flat auth map (wrong schema), an
        // empty settings stub, and a log-only dir — all must be rejected.
        try write(home, ".codex-work/auth.json", codexAuthJSON(accountID: "acct-work"))
        try write(home, ".pi-agent/auth.json", #"{"anthropic":{"type":"oauth","access":"x"}}"#)
        try write(home, ".openclaude/settings.json", "{}")
        try makeDir(home, ".codexcode/logs")

        let discovery = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        )
        let result = discovery.run()

        let summary = Set(result.instances.map { "\($0.baseProviderID)|\($0.identityKey)" })
        XCTAssertEqual(summary, ["claude|uuid-work", "codex|acct-work"])
        let work = result.instances.first { $0.identityKey == "uuid-work" }
        XCTAssertEqual(work?.identityLabel, "work@example.com")
        XCTAssertEqual(work?.kind, .claudeConfigDir)
    }

    func testDiscoveryFindsKeychainBackedHomes() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(home, ".claude.json", claudeIdentityJSON(uuid: "uuid-default", email: nil))
        // Keychain-backed extra Claude home: identity file present, no credentials file, but the
        // computed per-dir keychain item exists (attributes probe).
        try write(home, ".claude-work/.claude.json", claudeIdentityJSON(uuid: "uuid-work", email: nil))
        // Keyring-mode Codex home: no auth.json, but the home shape + its computed keychain account.
        try write(home, ".codex-keyring/config.toml", "model = \"gpt-5\"")

        let keychain = AccountAwareKeychain()
        let claudeDir = home.appendingPathComponent(".claude-work").path
        keychain.existingItems.insert("Claude Code-credentials-\(ProviderInstanceID.hash8(claudeDir))|*")
        let codexDir = home.appendingPathComponent(".codex-keyring").path
        keychain.existingItems.insert("Codex Auth|\(CodexAuthStore.keychainAccountName(forHome: codexDir))")

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            homeDirectory: { home }
        ).run()

        let byBase = Dictionary(grouping: result.instances, by: \.baseProviderID)
        XCTAssertEqual(byBase["claude"]?.first?.identityKey, "uuid-work")
        XCTAssertEqual(byBase["claude"]?.first?.keychainLiteral, claudeDir)
        XCTAssertEqual(byBase["codex"]?.first?.kind, .codexHome)
        XCTAssertEqual(byBase["codex"]?.first?.identityKey.hasPrefix("codex-home:"), true)
    }

    func testDiscoveryPartitionsCoworkSandboxesByOrganization() throws {
        // The real-world shape: ONE account (same email/UUID) belonging to two orgs — a personal Max
        // org (the CLI login) and a Team org used through Cowork. Plans are org-scoped, so the Team
        // org must become its own Desktop-backed instance, never merge into the default card.
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(home, ".claude.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@example.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        let sessions = "Library/Application Support/Claude/local-agent-mode-sessions"
        try write(home, "\(sessions)/g1/s1/local_a/.claude/.claude.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@example.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        try makeDir(home, "\(sessions)/g1/s1/local_a/.claude/projects")
        try write(home, "\(sessions)/g1/s1/local_b/.claude/.claude.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@example.com", orgUuid: "ORG-TEAM", orgName: "Team Org"))
        try makeDir(home, "\(sessions)/g1/s1/local_b/.claude/projects")

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()

        let desktop = result.instances.first { $0.kind == .claudeDesktop }
        XCTAssertEqual(desktop?.identityKey, "uuid-me|org-team")
        XCTAssertEqual(desktop?.desktopOrganization, "org-team")
        XCTAssertEqual(desktop?.identityLabel, "me@example.com (Team Org)")
        XCTAssertEqual(result.coworkRootsByIdentityKey["uuid-me|org-team"]?.count, 1)
        XCTAssertEqual(result.defaultClaudeCoworkRoots?.count, 1)
        XCTAssertEqual(result.defaultClaudeCoworkRoots?.first?.path.contains("local_a"), true)
    }

    func testDiscoveryWithoutExtraLoginsFindsNothing() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude.json", claudeIdentityJSON(uuid: "uuid-default", email: nil))
        try write(home, ".codex/auth.json", codexAuthJSON(accountID: "acct-default"))

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()

        XCTAssertTrue(result.instances.isEmpty)
        XCTAssertNil(result.defaultClaudeCoworkRoots)
        XCTAssertEqual(result.defaultIdentityKeys["claude"], ["uuid-default"])
        XCTAssertEqual(result.defaultIdentityKeys["codex"], ["acct-default"])
    }

    func testDiscoveryFindsParkedSwapSlots() throws {
        // cswap keeps a per-slot copy of `.claude.json` in its vault; the ACTIVE slot is what the
        // default card shows, so only parked slots become instances — and a parked slot whose
        // identity happens to equal the default is skipped too.
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        try write(home, ".claude-swap-backup/configs/.claude-config-1-me@x.com.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-TEAM", orgName: "Team Org"))
        try write(home, ".claude-swap-backup/configs/.claude-config-2-me@x.com.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        try write(home, ".claude-swap-backup/sequence.json", #"{"activeAccountNumber": 2}"#)

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()

        XCTAssertEqual(result.instances.count, 1)
        let slot = try XCTUnwrap(result.instances.first)
        XCTAssertEqual(slot.kind, .claudeSwapSlot)
        XCTAssertEqual(slot.identityKey, "uuid-me|org-team")
        XCTAssertEqual(slot.swapAccountName, "account-1-me@x.com")
        XCTAssertEqual(slot.desktopOrganization, "org-team")
        XCTAssertEqual(slot.identityLabel, "me@x.com (Team Org)")
        XCTAssertEqual(slot.anchorPath, home.appendingPathComponent(".claude-swap-backup").path)
    }

    func testReconcileUpgradesSourceKindForSameIdentity() {
        // The same account can migrate sources (Desktop-borrowed → cswap vault). The record keeps its
        // id and ordinal; the source description adopts the latest discovery.
        let defaults = makeScratchDefaults("KindUpgrade")
        let desktop = DiscoveredProviderInstance(
            baseProviderID: "claude", kind: .claudeDesktop,
            anchorPath: nil, keychainLiteral: nil, desktopOrganization: "org-team",
            identityKey: "uuid-me|org-team", identityLabel: "me@x.com (Team Org)"
        )
        let first = ProviderInstancesStore(defaults: defaults).reconcile(with: [desktop])

        let swap = DiscoveredProviderInstance(
            baseProviderID: "claude", kind: .claudeSwapSlot,
            anchorPath: "/Users/x/.claude-swap-backup", keychainLiteral: nil,
            desktopOrganization: "org-team", swapAccountName: "account-1-me@x.com",
            identityKey: "uuid-me|org-team", identityLabel: "me@x.com (Team Org)"
        )
        let next = ProviderInstancesStore(defaults: defaults).reconcile(with: [swap])

        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].id, first[0].id)
        XCTAssertEqual(next[0].ordinal, first[0].ordinal)
        XCTAssertEqual(next[0].kind, .claudeSwapSlot)
        XCTAssertEqual(next[0].swapAccountName, "account-1-me@x.com")
    }

    func testSwapSlotStoreReadsVaultReadOnly() throws {
        let keychain = AccountAwareKeychain()
        keychain.accountValues["claude-swap|account-1-me@x.com"] = claudeCredentialsJSON(access: "parked-token")
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            scope: .swapSlot(account: "account-1-me@x.com", backupRoot: "/Users/x/.claude-swap-backup", organization: nil)
        )

        let load = store.loadCredentialSet()
        let candidate = try XCTUnwrap(load.candidates.first)
        XCTAssertEqual(load.candidates.count, 1)
        XCTAssertEqual(candidate.source.label, "swapVault")
        XCTAssertEqual(candidate.oauth.accessToken, "parked-token")
        XCTAssertNil(candidate.oauth.refreshToken, "parked tokens must never be refreshable — rotating would corrupt cswap's backup")
        XCTAssertEqual(load.desktopStatus, .notChecked)
        XCTAssertTrue(store.hasCredentialFootprint())

        // Rotations are never written back.
        XCTAssertFalse(try store.save(candidateState(candidate), ifUnchanged: store.credentialGeneration()))
    }

    func testSwapSlotStoreFallsBackToEncFile() throws {
        let account = "account-1-me@x.com"
        let root = "/Users/x/.claude-swap-backup"
        let blob = Data(claudeCredentialsJSON(access: "enc-token").utf8).base64EncodedString()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["\(root)/credentials/.creds-1-me@x.com.enc": blob]),
            keychain: AccountAwareKeychain(),
            scope: .swapSlot(account: account, backupRoot: root, organization: nil)
        )
        XCTAssertEqual(store.loadCredentialSet().candidates.first?.oauth.accessToken, "enc-token")
        XCTAssertTrue(store.hasCredentialFootprint())
    }

    private func candidateState(_ state: ClaudeCredentialState) -> ClaudeCredentialState { state }

    // MARK: - Scoped credential stores

    func testScopedClaudeStoreReadsOnlyItsOwnLogin() {
        let files = FakeFiles([
            "/Users/x/.claude-work/.credentials.json": claudeCredentialsJSON(access: "token-work")
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-env-token"]),
            files: files,
            keychain: ServiceKeychain(),
            scope: .configDir(path: "/Users/x/.claude-work", keychainLiteral: "~/.claude-work")
        )

        XCTAssertEqual(
            store.keychainServiceCandidates(),
            ["Claude Code-credentials-\(ProviderInstanceID.hash8("~/.claude-work"))"]
        )

        let load = store.loadCredentialSet()
        XCTAssertEqual(load.candidates.map(\.source.label), ["file"])
        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "token-work")
        XCTAssertEqual(load.desktopStatus, .notChecked, "a config-dir instance must never consult Desktop")
        XCTAssertTrue(store.hasCredentialFootprint())
    }

    func testScopedClaudeStoreNeverFallsBackToBaseKeychainItem() {
        // Only the DEFAULT login's bare service item exists — the scoped instance must not see it.
        let keychain = ServiceKeychain(values: [
            "Claude Code-credentials": claudeCredentialsJSON(access: "default-token")
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            scope: .configDir(path: "/Users/x/.claude-work", keychainLiteral: "/Users/x/.claude-work")
        )
        XCTAssertTrue(store.loadCredentialSet().candidates.isEmpty)
        XCTAssertFalse(store.hasCredentialFootprint())
    }

    func testScopedCodexStorePinsPathsAndKeychainAccount() throws {
        let account = CodexAuthStore.keychainAccountName(forHome: "/Users/x/.codex-work")
        XCTAssertTrue(account.hasPrefix("cli|"))
        XCTAssertEqual(account.count, "cli|".count + 16)

        let keychain = AccountAwareKeychain()
        keychain.accountValues["Codex Auth|\(account)"] = codexAuthJSON(accountID: "acct-work")
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/Users/x/.elsewhere"]),
            files: FakeFiles(),
            keychain: keychain,
            scope: .home(path: "/Users/x/.codex-work")
        )

        XCTAssertEqual(store.authPaths(), ["/Users/x/.codex-work/auth.json"])
        let loaded = store.loadKeychainAuth()
        XCTAssertEqual(loaded?.auth.tokens?.accountID, "acct-work")

        // Rotations write back to the same account-scoped item, never the bare service.
        var state = try XCTUnwrap(loaded)
        state.auth.tokens?.accessToken = "rotated"
        try store.save(state)
        XCTAssertEqual(keychain.lastAccountWrite?.0, "Codex Auth|\(account)")
    }

    // MARK: - Defaults translation + ordering

    func testDefaultLayoutTranslatesBaseEntriesOntoInstances() {
        let instanceID = ProviderInstanceID.make(baseProviderID: "claude", identityKey: "uuid-work")
        let translated = DefaultLayout.translatedForInstances(
            DefaultLayout.metricIDs,
            providerIDs: ["claude", instanceID, "codex"]
        )
        XCTAssertTrue(translated.contains("claude.session"))
        XCTAssertTrue(translated.contains("\(instanceID).session"))
        XCTAssertTrue(translated.contains("\(instanceID).last30"))
        XCTAssertFalse(translated.contains("\(instanceID).codex.session"))

        // No instances: byte-identical list.
        XCTAssertEqual(
            DefaultLayout.translatedForInstances(DefaultLayout.metricIDs, providerIDs: ["claude", "codex"]),
            DefaultLayout.metricIDs
        )
    }

    func testOrderedProviderIDsInsertsInstancesAfterTheirBase() {
        let instanceID = ProviderInstanceID.make(baseProviderID: "claude", identityKey: "uuid-work")
        let registry = WidgetRegistry(
            providers: [
                Provider(id: "claude", displayName: "Claude 1", icon: .providerMark("claude")),
                Provider(id: instanceID, displayName: "Claude 2", icon: .providerMark("claude")),
                Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
            ],
            descriptors: []
        )
        // Existing saved order without the instance: it slots in right after Claude, not at the end.
        XCTAssertEqual(
            registry.orderedProviderIDs(savedOrder: ["codex", "claude"]),
            ["codex", "claude", instanceID]
        )
        // A brand-new non-instance provider still appends at the end (unchanged behavior).
        XCTAssertEqual(
            registry.orderedProviderIDs(savedOrder: []),
            ["claude", instanceID, "codex"]
        )
    }

    // MARK: - Catalog

    func testCatalogWithoutContextIsUnchanged() {
        let ids = ProviderCatalog.make(defaults: makeScratchDefaults("Catalog")).map(\.provider.id)
        XCTAssertEqual(ids, [
            "claude", "codex", "cursor", "antigravity", "copilot",
            "devin", "grok", "opencode", "openrouter", "zai"
        ])
    }

    func testCatalogBuildsInstanceRuntimesAfterTheirBase() {
        let record = ProviderInstanceRecord(
            id: ProviderInstanceID.make(baseProviderID: "claude", identityKey: "uuid-work"),
            baseProviderID: "claude",
            ordinal: 2,
            kind: .claudeConfigDir,
            anchorPath: "/Users/x/.claude-work",
            keychainLiteral: "~/.claude-work",
            identityKey: "uuid-work",
            identityLabel: "work@example.com"
        )
        let runtimes = ProviderCatalog.make(
            defaults: makeScratchDefaults("CatalogInstances"),
            instanceContext: ProviderInstanceContext(records: [record])
        )

        let ids = runtimes.map(\.provider.id)
        XCTAssertEqual(ids[0], "claude")
        XCTAssertEqual(ids[1], record.id)
        XCTAssertEqual(ids[2], "codex")

        XCTAssertEqual(runtimes[0].provider.displayName, "Claude 1")
        XCTAssertEqual(runtimes[1].provider.displayName, "Claude 2")
        XCTAssertEqual(runtimes[2].provider.displayName, "Codex")

        // Instance descriptors are namespaced under the instance id, defaults stay byte-identical.
        XCTAssertTrue(runtimes[1].widgetDescriptors.allSatisfy { $0.id.hasPrefix("\(record.id).") })
        XCTAssertTrue(runtimes[0].widgetDescriptors.contains { $0.id == "claude.session" })
    }

    // MARK: - Fixtures

    private func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderInstances.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeFixtureHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-instances-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDir(_ home: URL, _ relative: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(relative),
            withIntermediateDirectories: true
        )
    }

    private func write(_ home: URL, _ relative: String, _ contents: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func claudeIdentityJSON(uuid: String, email: String?, orgUuid: String? = nil, orgName: String? = nil) -> String {
        var fields = ["\"accountUuid\": \"\(uuid)\""]
        if let email { fields.append("\"emailAddress\": \"\(email)\"") }
        if let orgUuid { fields.append("\"organizationUuid\": \"\(orgUuid)\"") }
        if let orgName { fields.append("\"organizationName\": \"\(orgName)\"") }
        return #"{"oauthAccount": {\#(fields.joined(separator: ", "))}, "userID": "irrelevant"}"#
    }

    private func claudeCredentialsJSON(access: String) -> String {
        #"{"claudeAiOauth": {"accessToken": "\#(access)", "refreshToken": "r", "expiresAt": 9999999999999, "subscriptionType": "max", "scopes": ["user:profile", "user:inference"]}}"#
    }

    private func codexAuthJSON(accountID: String) -> String {
        #"{"OPENAI_API_KEY": null, "tokens": {"id_token": "x.y.z", "access_token": "at", "refresh_token": "rt", "account_id": "\#(accountID)"}, "last_refresh": "2026-07-16T00:00:00Z"}"#
    }
}

/// A keychain double that models per-(service, account) items: `existingItems` answers the
/// attributes-only probe (`service|account`, with `service|*` matching any account), `accountValues`
/// backs account-scoped reads, and account-scoped writes are recorded for assertions.
final class AccountAwareKeychain: KeychainAccessing, @unchecked Sendable {
    var existingItems: Set<String> = []
    var accountValues: [String: String] = [:]
    var lastAccountWrite: (String, String)?

    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}

    func readGenericPassword(service: String, account: String) throws -> String? {
        accountValues["\(service)|\(account)"]
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        lastAccountWrite = ("\(service)|\(account)", value)
        accountValues["\(service)|\(account)"] = value
    }

    func hasGenericPassword(service: String, account: String?) -> Bool {
        if existingItems.contains("\(service)|*") { return true }
        if let account {
            return existingItems.contains("\(service)|\(account)") || accountValues["\(service)|\(account)"] != nil
        }
        return existingItems.contains { $0.hasPrefix("\(service)|") } || accountValues.keys.contains { $0.hasPrefix("\(service)|") }
    }
}
