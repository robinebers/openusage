import XCTest
@testable import OpenUsage

/// How managed Codex homes join the launch-time account pass: card ids, writable sources, history
/// ownership, and the signed-out card that keeps Sign In Again reachable.
@MainActor
final class CodexManagedAccountDiscoveryTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private static let managedRoot = "/Users/dev/Library/Application Support/OpenUsage/codex-accounts/com.example"

    private func assemble(files: FakeFiles, managed: [CodexManagedLogin], defaults: UserDefaults? = nil) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(),
            homeDirectory: { Fixtures.home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults ?? makeScratchDefaults()),
            families: ["codex"],
            managedCodexLogins: managed,
            listCodexHomeDirectories: { _ in [] }
        )
    }

    private func managedLogin(home: String, identityKey: String) -> CodexManagedLogin {
        CodexManagedLogin(id: UUID(), home: home, identityKey: identityKey, createdAt: Date(), lastSignedInAt: Date())
    }

    func testManagedHomeWithAnotherAccountBecomesItsOwnWritableCard() async {
        let home = "\(Self.managedRoot)/A"
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ])

        let assembly = await assemble(files: files, managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")])

        XCTAssertEqual(assembly.codexCards.map(\.id), ["codex", "codex@\(ProviderAccountID.make(family: "codex", identityKey: "acct-b|bob@test").dropFirst(6))"])
        let bob = assembly.codexCards[1]
        XCTAssertEqual(bob.authHomes, [home])
        XCTAssertEqual(bob.writableAuthHomes, [home])
        XCTAssertTrue(assembly.codex.historyHomes.homes.contains(home))
    }

    func testManagedHomeWithTheDefaultAccountJoinsTheSameCard() async {
        let home = "\(Self.managedRoot)/A"
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])

        let assembly = await assemble(files: files, managed: [managedLogin(home: home, identityKey: "acct-a|alice@test")])

        // One account, two logins: still one card under the bare id, with both homes as writable
        // sources — and scoped, so its cache and synced history carry the identity.
        XCTAssertEqual(assembly.codexCards.map(\.id), ["codex"])
        XCTAssertEqual(assembly.codexCards.first?.authHomes, ["/Users/dev/.codex", home])
        XCTAssertEqual(assembly.codexCards.first?.writableAuthHomes, ["/Users/dev/.codex", home])
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-a|alice@test")
    }

    func testTheOnlyLoginBeingManagedStillGetsAScopedCard() async {
        let home = "\(Self.managedRoot)/A"
        let files = FakeFiles([
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ])

        let assembly = await assemble(files: files, managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")])

        // The plain, unscoped card would stamp nothing and count every home; a managed login always
        // gets an account card, keeping the bare id so layout and pins carry over.
        XCTAssertEqual(assembly.codexCards.map(\.id), ["codex"])
        XCTAssertEqual(assembly.codexCards.first?.writableAuthHomes, [home])
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-b|bob@test")
    }

    func testSignedOutManagedHomeKeepsOwningItsSessions() async {
        let home = "\(Self.managedRoot)/A"
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])

        let assembly = await assemble(files: files, managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")])

        XCTAssertTrue(assembly.codex.historyHomes.homes.contains(home))
        XCTAssertEqual(assembly.codex.historyHomes.registeredOwners[home]?.email, "bob@test")
    }

    func testSignedOutManagedLoginKeepsItsCardAndItsID() async {
        let home = "\(Self.managedRoot)/A"
        let defaults = makeScratchDefaults()
        let managed = [managedLogin(home: home, identityKey: "acct-b|bob@test")]
        let signedIn = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ]), managed: managed, defaults: defaults)

        // The token lapsed: the card must survive, under the same id, so Sign In Again finds it.
        let signedOut = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ]), managed: managed, defaults: defaults)

        XCTAssertEqual(signedOut.codexCards.map(\.id), signedIn.codexCards.map(\.id))
        XCTAssertEqual(signedOut.codexCards.count, 2)
        let bob = signedOut.codexCards[1]
        XCTAssertEqual(bob.identity.email, "bob@test")
        XCTAssertTrue(bob.authHomes.isEmpty)
        XCTAssertEqual(bob.displayName, "Codex: bob@test")
        XCTAssertEqual(signedOut.codex.externalIdentityKeys, ["acct-a|alice@test"])
        // Its "no valid login" advice points at Codex Accounts; Alice's at her tools.
        XCTAssertTrue(bob.hasManagedLogin)
        XCTAssertFalse(signedOut.codexCards[0].hasManagedLogin)
        XCTAssertTrue(CodexAccountLoginError(managed: true).localizedDescription.contains("Codex → Codex Accounts."))
        XCTAssertTrue(CodexAccountLoginError(managed: false).localizedDescription.contains("with Codex, xswap, or pi, then refresh"))
    }

    func testTheCatalogAndTheProviderCarryTheManagedLoginAdvice() async {
        // The flag must survive the catalog, and the provider must put it on its error.
        let home = "\(Self.managedRoot)/A"
        let managed = [managedLogin(home: home, identityKey: "acct-b|bob@test")]
        let assembly = await assemble(files: FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ]), managed: managed)
        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
            .compactMap { $0 as? CodexProvider }
        XCTAssertEqual(providers.map(\.hasManagedLogin), [false, true])

        let bob = assembly.codexCards[1]
        let signedOut = CodexProvider.isolated(
            provider: CodexProvider.makeProvider(id: bob.id, displayName: bob.displayName),
            authStore: CodexAuthStore(
                environment: FakeEnvironment([:]), files: FakeFiles(), keychain: FakeKeychain(),
                expectedIdentity: bob.identity, additionalAuthHomes: bob.authHomes
            ),
            hasManagedLogin: true
        )
        let snapshot = await signedOut.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        let advice = snapshot.lines.contains { line in
            if case .badge(_, let text, _, _) = line { return text.contains("Codex → Codex Accounts.") }
            return false
        }
        XCTAssertTrue(advice, "\(snapshot.lines)")
    }

    func testALaunchWithoutCodexDiscoveryLeavesTheOtherLoginsUnknown() async {
        // Not "no other logins" but "unknown": Add must refuse rather than trust an empty set.
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: FakeFiles(), keychain: FakeKeychain(),
            homeDirectory: { Fixtures.home }
        )
        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["claude"], managedCodexLogins: [], listCodexHomeDirectories: { _ in [] }
        )
        XCTAssertNil(assembly.codex.externalIdentityKeys)
    }

    func testFirstManagedLoginLeavesTheBareIDWithTheExistingPiAccount() async {
        let home = "\(Self.managedRoot)/B"
        // Alice only ever signed in through pi: no account record exists yet, so the id is minted now.
        let files = FakeFiles([
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex", "ACCT-A", "alice@test")]),
            "\(home)/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ])

        let assembly = await assemble(files: files, managed: [managedLogin(home: home, identityKey: "acct-b|bob@test")])

        XCTAssertEqual(assembly.codexCards.map(\.identity.email), ["alice@test", "bob@test"])
        XCTAssertEqual(assembly.codexCards.first?.id, "codex")
        XCTAssertTrue(assembly.codexCards[1].id.hasPrefix("codex@"))
        XCTAssertTrue(assembly.codex.isAccountAware)
    }

    func testInstallsWithoutManagedLoginsAreUntouched() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])

        let assembly = await assemble(files: files, managed: [])

        // The lone external login keeps the plain card exactly as before this feature, including
        // the default-home observer's workspace-only identity stamp.
        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-a")
        XCTAssertEqual(assembly.codex.externalIdentityKeys, ["acct-a|alice@test"])
        XCTAssertFalse(assembly.codex.isAccountAware)
    }

    func testAnAccountAwareInstallWithNoLoginLeftTakesNoPeerHistory() {
        let now = Date()
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 123, costUSD: 1),
        ]))
        let stamped = UsageHistoryDocument(
            schema: UsageHistoryDocument.accountSchema, deviceID: "peer", deviceName: "Peer", updatedAt: now,
            providers: ["codex": history], identities: ["codex": "acct-z|zoe@test"]
        )
        let legacy = UsageHistoryDocument(deviceID: "legacy", deviceName: "Legacy", updatedAt: now, providers: ["codex": history])
        let descriptors = ["codex": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")]

        // Every login removed: the plain fallback card names no account and merges nothing.
        let accountAware = UsageHistoryAggregator.merged(
            localSnapshots: [:], peerDocuments: [stamped, legacy], descriptors: descriptors,
            providerIdentityKeys: [:], accountAwareFamilies: ["codex"], now: now
        )
        XCTAssertNil(accountAware["codex"])

        // A legacy install (never account-aware) keeps merging as it always did.
        let legacyInstall = UsageHistoryAggregator.merged(
            localSnapshots: [:], peerDocuments: [legacy], descriptors: descriptors, providerIdentityKeys: [:], now: now
        )
        XCTAssertEqual(legacyInstall["codex"]?.series.daily.first?.totalTokens, 123)
    }
}
