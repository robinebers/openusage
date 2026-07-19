import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testADistinctConfigDirAccountMintsAHashedRecordAndAnExtraCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertTrue(card.id.hasPrefix("claude@"), "a config-dir account never claims the bare id")
        XCTAssertEqual(card.displayName, "Claude — Sunstory")
        XCTAssertEqual(card.credential, .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work"))
        XCTAssertEqual(card.logRoots.map(\.path), ["/Users/dev/.claude-work"])
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2")
        // The registry recorded both: the default holder under the bare id, the extra account with
        // its config-dir source.
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.configDir])
        XCTAssertEqual(record.label, "work@example.com (Sunstory)")
        XCTAssertTrue(assembly.defaultClaudeExtraLogRoots.isEmpty)
    }

    func testASameAccountConfigDirFoldsOntoTheDefaultCardAsALogRoot() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-side/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.claude-side/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty, "one account never renders as two cards")
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-side"])
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(Set(record.sources.map(\.kind)), [.defaultHome, .configDir])
    }

    func testAnUnresolvedDefaultLoginSkipsCandidatesThisLaunch() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Credentials exist but the state file names no account → unresolved, footprint present.
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(
            assembly.claudeCards.isEmpty,
            "with a nameless default login, an accepted candidate could be that very account — skip"
        )
        XCTAssertTrue(store.records.isEmpty)
    }

    func testNoDefaultLoginStillAcceptsAConfigDirOnlyAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertTrue(
            card.id.hasPrefix("claude@"),
            "the bare id stays reserved for a future default-home login even when it is free"
        )
    }

    // MARK: - Cowork sandboxes

    private let coworkBase = "/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/g/s"

    private func makeCoworkDiscovery(
        files: [String: String],
        sandboxes: [String]
    ) -> ClaudeCoworkDiscovery {
        ClaudeCoworkDiscovery(
            files: FakeFiles(files),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in sandboxes.map { URL(fileURLWithPath: $0) } }
        )
    }

    private func makeDefaultResolvedObserver() -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    func testDefaultAccountSandboxesLeaveTheBuiltInCoworkWalkUntouched() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertNil(assembly.defaultClaudeCoworkRoots, "no partition — the scanner's built-in walk stays byte-identical")
    }

    func testADistinctCoworkAccountBecomesOneDesktopBackedCardAndPartitionsTheWalk() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let mine = "\(coworkBase)/local_1/.claude"
        let theirsA = "\(coworkBase)/local_2/.claude"
        let theirsB = "\(coworkBase)/local_3/.claude"
        let identity = #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2", "organizationName": "Sunstory"}}"#
        let cowork = makeCoworkDiscovery(
            files: [
                mine + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                theirsA + "/.claude.json": identity,
                theirsB + "/.claude.json": identity,
            ],
            sandboxes: [mine, theirsA, theirsB]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1, "several sandboxes of one account are ONE card")
        XCTAssertEqual(card.credential, .desktop(organization: "org-2"))
        XCTAssertEqual(card.displayName, "Claude — Sunstory")
        XCTAssertEqual(card.logRoots.map(\.path), [theirsA, theirsB])
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2|org-2")
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots?.map(\.path), [mine], "the default card keeps exactly its own sandboxes")
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.desktop])
    }

    func testCoworkSandboxesOfAConfigDirAccountAttachAsItsLogRoots() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(),
            accountsStore: store,
            claudeDiscovery: discovery,
            coworkDiscovery: cowork
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1, "the sandbox joins the config-dir card instead of minting a second one")
        XCTAssertEqual(card.credential, .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work"))
        XCTAssertEqual(card.logRoots.map(\.path), ["/Users/dev/.claude-work", sandbox])
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots?.map(\.path), [], "the other account's sandbox leaves the default walk")
    }

    func testADistinctCoworkAccountWithoutAnOrgPinGetsNoCardButStaysOutOfTheDefaultWalk() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            // An account UUID but no org: Desktop caches tokens per org, so there is no safe
            // credential pin for a card.
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-3"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(
            assembly.defaultClaudeCoworkRoots?.map(\.path), [],
            "another account's sessions must still not bleed into the default card's spend"
        )
        XCTAssertEqual(store.records.count, 1, "only the default account has a record")
    }

    func testAnUnidentifiedSandboxStaysOnTheDefaultCardEvenWhenAPartitionExists() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let nameless = "\(coworkBase)/local_1/.claude"
        let theirs = "\(coworkBase)/local_2/.claude"
        let cowork = makeCoworkDiscovery(
            files: [theirs + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#],
            sandboxes: [nameless, theirs]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertEqual(
            assembly.defaultClaudeCoworkRoots?.map(\.path), [nameless],
            "a sandbox naming no account keeps counting on the default card, as the built-in walk always has"
        )
    }

    func testASandboxMissingItsOrgHalfStillCountsAsTheDefaultAccount() {
        // Identity files sometimes omit the org (older files, files written mid-login). Same
        // account uuid = same login: the sandbox must stay on the default card, not become a
        // phantom second account that partitions the walk.
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "organizationUuid": "ORG-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertNil(assembly.defaultClaudeCoworkRoots, "no partition — same login, org half or not")
    }

    func testASandboxCarryingAnOrgTheBareDefaultKeyLacksStillCountsAsTheDefaultAccount() {
        // The mirror case: the DEFAULT identity file is the one missing its org half.
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "organizationUuid": "ORG-1"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertNil(assembly.defaultClaudeCoworkRoots)
    }

    func testATruncatedCoworkScanSkipsRoutingThisLaunch() {
        // A partial sandbox list must not drive routing: a missed non-default sandbox would bleed
        // into the default card, and a partial partition would drop default spend. The pass skips
        // wholesale and the next launch retries.
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let theirs = "\(coworkBase)/local_1/.claude"
        let cowork = ClaudeCoworkDiscovery(
            files: FakeFiles([theirs + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#]),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in [URL(fileURLWithPath: theirs)] },
            timeBudget: -1
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertNil(assembly.defaultClaudeCoworkRoots, "no partition from a partial walk — the built-in walk stays byte-identical")
    }

    func testAConfigDirMissingItsOrgHalfFoldsOntoTheDefaultCard() throws {
        // The same one-login-two-key-shapes rule applies to config dirs: a dir whose identity file
        // omits the org must fold onto the default card, never mint a duplicate.
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "organizationUuid": "ORG-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-side/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.claude-side/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-side"])
    }

    func testARenameNeverBakesIntoTheCardOnlyTheResolverCarriesIt() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        // First pass creates the record; the user then renames it.
        let first = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let cardID = try XCTUnwrap(first.claudeCards.first?.id)
        XCTAssertEqual(first.claudeCards.first?.displayName, cardID, "no label → the short-hash id fallback")
        store.rename(cardID: cardID, to: "Work Max")

        let reloadedStore = ProviderAccountsStore(defaults: defaults)
        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: reloadedStore,
            claudeDiscovery: discovery
        )
        // The baked card name stays the DERIVED default — a rename lives only in the registry and
        // is resolved at render time, so a baked name can never be a stale copy of it.
        XCTAssertEqual(second.claudeCards.first?.displayName, cardID)
        XCTAssertEqual(reloadedStore.resolvedDisplayName(cardID: cardID), "Work Max")
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }
}
