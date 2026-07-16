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

    func testReconcileUpgradesPathKeyedRecordWhenIdentityBecomesReadable() {
        // A keyring-mode Codex home is path-keyed until auth.json (re)appears. Both readability
        // flips must resolve to the SAME record — one home never becomes two cards.
        let defaults = makeScratchDefaults("PathUpgrade")
        let store = ProviderInstancesStore(defaults: defaults)
        let home = "/Users/x/.codex-work"

        let pathKeyed = DiscoveredProviderInstance(
            baseProviderID: "codex", kind: .codexHome,
            anchorPath: home, keychainLiteral: nil,
            identityKey: ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: home),
            identityLabel: nil
        )
        let first = store.reconcile(with: [pathKeyed])
        XCTAssertEqual(first.count, 1)

        // auth.json appears: same home, real account identity → same record, upgraded in place.
        let identified = DiscoveredProviderInstance(
            baseProviderID: "codex", kind: .codexHome,
            anchorPath: home, keychainLiteral: nil,
            identityKey: "acct-work", identityLabel: "work@example.com"
        )
        let upgraded = ProviderInstancesStore(defaults: defaults).reconcile(with: [identified])
        XCTAssertEqual(upgraded.count, 1, "identity upgrade must not mint a second card for the same home")
        XCTAssertEqual(upgraded[0].id, first[0].id, "instance id (layout key) survives the upgrade")
        XCTAssertEqual(upgraded[0].ordinal, first[0].ordinal)
        XCTAssertEqual(upgraded[0].identityKey, "acct-work")
        XCTAssertEqual(upgraded[0].identityLabel, "work@example.com")

        // Keyring mode again (auth.json gone): the path-keyed finding matches the same record and
        // the known identity is kept, not wiped.
        let downgraded = ProviderInstancesStore(defaults: defaults).reconcile(with: [pathKeyed])
        XCTAssertEqual(downgraded.count, 1)
        XCTAssertEqual(downgraded[0].identityKey, "acct-work")

        // A different home stays a different record.
        let other = DiscoveredProviderInstance(
            baseProviderID: "codex", kind: .codexHome,
            anchorPath: "/Users/x/.codex-other", keychainLiteral: nil,
            identityKey: ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: "/Users/x/.codex-other"),
            identityLabel: nil
        )
        XCTAssertEqual(ProviderInstancesStore(defaults: defaults).reconcile(with: [other]).count, 2)
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

        // The support trail explains every decision — and never leaks an email (labels stay out;
        // the log file ends up attached to public issues).
        XCTAssertTrue(result.notes.contains { $0.contains(".claude-copy") && $0.contains("folded") })
        XCTAssertTrue(result.notes.contains { $0.contains(".claude-work") && $0.contains("accepted") })
        XCTAssertFalse(result.notes.contains { $0.contains("work@example.com") })
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

    func testKeychainProbeHonorsOAuthEnvSuffix() throws {
        // Non-prod OAuth setups suffix the keychain service ("Claude Code-staging-oauth-credentials-…").
        // Discovery must build the same name the scoped store later reads, or staging users' extra
        // accounts pass discovery without their keychain credential (or miss it entirely).
        let stagingEnv = FakeEnvironment(["USER_TYPE": "ant", "USE_STAGING_OAUTH": "1"])
        XCTAssertEqual(
            ClaudeAuthStore.baseKeychainServiceName(environment: stagingEnv),
            "Claude Code-staging-oauth-credentials"
        )
        XCTAssertEqual(
            ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:])),
            "Claude Code-credentials"
        )

        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude.json", claudeIdentityJSON(uuid: "uuid-default", email: nil))
        try write(home, ".claude-work/.claude.json", claudeIdentityJSON(uuid: "uuid-work", email: nil))

        let keychain = AccountAwareKeychain()
        let claudeDir = home.appendingPathComponent(".claude-work").path
        keychain.existingItems.insert(
            "\(ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: claudeDir, environment: stagingEnv))|*"
        )

        let result = ProviderInstanceDiscovery(
            environment: stagingEnv,
            keychain: keychain,
            homeDirectory: { home }
        ).run()
        XCTAssertEqual(result.instances.first?.identityKey, "uuid-work")
    }

    func testXDGDefaultHomeIsTheDefaultCardNotAnInstance() throws {
        // A user whose default Claude data lives under $XDG_CONFIG_HOME/claude: that dir supplies the
        // default identity and is excluded from candidates — it must never appear as "Claude 2".
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".config/claude/.claude.json", claudeIdentityJSON(uuid: "uuid-default", email: nil))
        try write(home, ".config/claude/.credentials.json", claudeCredentialsJSON(access: "token-default"))
        try write(home, ".claude-work/.claude.json", claudeIdentityJSON(uuid: "uuid-work", email: nil))
        try write(home, ".claude-work/.credentials.json", claudeCredentialsJSON(access: "token-work"))

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()

        XCTAssertEqual(result.instances.map(\.identityKey), ["uuid-work"])
        XCTAssertEqual(result.defaultIdentityKeys["claude"], ["uuid-default"])
    }

    func testSkipsCandidatesWhenDefaultLoginCannotBeNamed() throws {
        // Default logins exist (keychain/keyring footprint) but their identity files are unreadable:
        // folding would be blind, so candidates are skipped this launch instead of risking the same
        // account on two cards. A footprint-free machine (no default login at all) keeps accepting.
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude-work/.claude.json", claudeIdentityJSON(uuid: "uuid-work", email: nil))
        try write(home, ".claude-work/.credentials.json", claudeCredentialsJSON(access: "token-work"))
        try write(home, ".codex-work/auth.json", codexAuthJSON(accountID: "acct-work"))
        try write(home, ".codex/config.toml", "model = \"gpt-5\"")

        let keychain = AccountAwareKeychain()
        keychain.existingItems.insert("Claude Code-credentials|*")
        keychain.existingItems.insert(
            "Codex Auth|\(CodexAuthStore.keychainAccountName(forHome: home.appendingPathComponent(".codex").path))"
        )

        // A cswap vault on the same machine: the guard must cover it too — parked slots can't fold
        // against a nameless default, and a timeline without the default card's filter would make the
        // unfiltered default scanner double-count the slot cards' shared-home slices.
        try write(home, ".claude-swap-backup/configs/.claude-config-1-a@x.com.json",
                  claudeIdentityJSON(uuid: "uuid-a", email: "a@x.com"))
        try write(home, ".claude-swap-backup/sequence.json", #"{"activeAccountNumber": 2}"#)
        try write(home, ".claude-swap-backup/claude-swap.log",
                  "2026-07-16 11:50:55,324 - INFO - Switched from account 1 to 2\n")

        let blocked = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            homeDirectory: { home }
        ).run()
        XCTAssertTrue(blocked.instances.isEmpty)
        XCTAssertNil(blocked.claudeSwapTimeline, "no timeline without a nameable default card")
        XCTAssertEqual(blocked.basesWithUnreadableDefault, ["claude", "codex"])
        XCTAssertTrue(blocked.notes.contains { $0.contains("claude: default login present but its identity is unreadable") })
        XCTAssertTrue(blocked.notes.contains { $0.contains("codex: default login present but its identity is unreadable") })

        let open = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()
        XCTAssertEqual(
            Set(open.instances.map(\.identityKey)),
            ["uuid-work", "acct-work", "uuid-a"],
            "with no default footprint there is nothing to duplicate — custom-dir-only logins (and parked vault slots) still get cards"
        )
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
        XCTAssertTrue(result.notes.contains { $0.contains("cswap vault") && $0.contains("active=2") })
        XCTAssertTrue(result.notes.contains { $0.contains("cswap slot 2") && $0.contains("active") })
        XCTAssertFalse(result.notes.contains { $0.contains("me@x.com") }, "vault notes must not carry the email")
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

    // MARK: - Swap timeline (per-account spend attribution)

    func testSwapTimelineParsesAndAttributes() throws {
        let log = """
        2026-07-16 10:00:00,123 - INFO - Starting up
        2026-07-16 11:50:55,324 - INFO - Switched from account 1 to 2
        2026-07-16 17:06:43,425 - INFO - Switched from account 2 to 1
        garbage line
        """
        let timeline = try XCTUnwrap(ClaudeSwapTimeline.parse(
            logText: log,
            slotIdentities: ["1": "uuid|org-team", "2": "uuid|org-max"]
        ))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func at(_ s: String) -> Date { formatter.date(from: s)! }

        // Backfill: slot 1 (the first event's `from`) owns everything before the first switch.
        XCTAssertEqual(timeline.identityKey(at: at("2026-07-10 09:00:00")), "uuid|org-team")
        XCTAssertEqual(timeline.identityKey(at: at("2026-07-16 12:00:00")), "uuid|org-max")
        XCTAssertEqual(timeline.identityKey(at: at("2026-07-16 18:00:00")), "uuid|org-team")

        // Filters: each account keeps its own periods; only the unknown-inclusive filter would take
        // time the timeline can't attribute (none here, thanks to the backfill).
        let team = timeline.entryFilter(identityKey: "uuid|org-team", includeUnknown: false)
        let max = timeline.entryFilter(identityKey: "uuid|org-max", includeUnknown: true)
        XCTAssertTrue(team(at("2026-07-16 09:00:00")))
        XCTAssertFalse(team(at("2026-07-16 12:00:00")))
        XCTAssertTrue(max(at("2026-07-16 12:00:00")))
        XCTAssertFalse(max(at("2026-07-16 18:00:00")))
    }

    func testSwapTimelineNilWithoutEvents() {
        XCTAssertNil(ClaudeSwapTimeline.parse(logText: "no switches here", slotIdentities: ["1": "x"]))
    }

    func testDiscoveryBuildsSwapTimeline() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        try write(home, ".claude-swap-backup/configs/.claude-config-1-me@x.com.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-TEAM", orgName: "Team Org"))
        try write(home, ".claude-swap-backup/configs/.claude-config-2-me@x.com.json",
                  claudeIdentityJSON(uuid: "uuid-me", email: "me@x.com", orgUuid: "ORG-MAX", orgName: "Max Org"))
        try write(home, ".claude-swap-backup/sequence.json", #"{"activeAccountNumber": 2}"#)
        try write(home, ".claude-swap-backup/claude-swap.log",
                  "2026-07-16 11:50:55,324 - INFO - Switched from account 1 to 2\n")

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        ).run()

        let timeline = try XCTUnwrap(result.claudeSwapTimeline)
        XCTAssertEqual(timeline.periods.count, 2)
        // Shared roots mirror the scanner's full default resolution — the XDG variant included, so a
        // cswap machine keeping logs under ~/.config/claude still gets attributed spend.
        XCTAssertEqual(result.claudeSharedHomeRoots, [
            home.appendingPathComponent(".config/claude"),
            home.appendingPathComponent(".claude")
        ])
        XCTAssertTrue(result.notes.contains { $0.contains("per-account spend attribution active") })
    }

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

    func testDisplayNamesNeverShowOrdinalGaps() {
        // A suppressed record (its account currently the default login — common with swap tools)
        // must not make the surviving card read "Claude 3": display rank counts VISIBLE cards only,
        // while persisted ordinals stay the stable sort key underneath.
        let survivor = ProviderInstanceRecord(
            id: "claude@b2d3867d", baseProviderID: "claude", ordinal: 3,
            kind: .claudeSwapSlot, anchorPath: "/Users/x/.claude-swap-backup",
            keychainLiteral: nil, swapAccountName: "account-2-me@x.com",
            identityKey: "uuid|org-max", identityLabel: nil
        )
        let context = ProviderInstanceContext(records: [survivor])
        XCTAssertEqual(context.displayName(for: survivor, baseName: "Claude"), "Claude 2")

        let runtimes = ProviderCatalog.make(
            defaults: makeScratchDefaults("DisplayRank"),
            instanceContext: context
        )
        XCTAssertEqual(runtimes[1].provider.displayName, "Claude 2")
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
