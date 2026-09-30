import XCTest
@testable import OpenUsage

/// Turning discovered Codex logins into cards: identity merging, card ids, and spend attribution.
@MainActor
final class CodexMultiAccountAssemblyTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures

    private func assemble(
        files: FakeFiles,
        directories: [String: [String]] = [:],
        environment: [String: String] = [:],
        home: URL = Fixtures.home,
        defaults: UserDefaults? = nil
    ) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults ?? makeScratchDefaults()),
            families: ["codex"],
            listCodexHomeDirectories: { directories[$0] ?? [] }
        )
    }

    private func provider(for card: CodexAccountCard, files: FakeFiles, environment: [String: String],
                          now: Date, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(environment), files: files, keychain: FakeKeychain(), now: { now },
                expectedIdentity: card.identity, additionalAuthHomes: card.authHomes,
                piCredentialSources: card.piCredentialSources
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )
    }

    func testSingleAccountAcrossHomeAndPiStaysOnThePlainCodexProvider() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex", "ACCT-A", "alice@test")]),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work"]])

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-a")
    }

    func testIncompletePiLoginBesideOnePlainAccountHidesUnattributedSpend() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex", "ACCT-B", "")]),
        ])

        let assembly = await assemble(files: files)
        let codex = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
            .compactMap { $0 as? CodexProvider }

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertFalse(assembly.codex.allowsUnattributedHistory)
        XCTAssertEqual(codex.map(\.provider.id), ["codex"])
        XCTAssertEqual(codex.map(\.allowsUnattributedHistory), [false])
    }

    func testPiLoginNeverRenamesASwapAlias() async throws {
        let swap = #"{"schemaVersion":1,"mainHome":"/Users/dev/.codex","accounts":[{"number":1,"alias":"Personal","home":"/Users/dev/.xswap/a","identity":{"accountId":"ACCT-A","email":"alice@test"}}]}"#
        let files = FakeFiles([
            "/Users/dev/.xswap/accounts.json": swap,
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex", "ACCT-A", "alice@test")]),
        ])

        let assembly = await assemble(files: files, environment: ["XSWAP_HOME": "/Users/dev/.xswap"])

        XCTAssertEqual(assembly.codexCards.map(\.displayName), ["Codex: Personal (alice@test)"])
    }

    func testAccountIDOnlyDefaultHomeStaysOwnCardBesideCompleteSibling() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: ""),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "b@test"),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work"]])

        XCTAssertEqual(assembly.codexCards.count, 2)
        let accountA = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "acct-a" })
        let accountB = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "acct-b" })
        XCTAssertEqual(accountA.id, "codex")
        XCTAssertTrue(accountA.authHomes.contains("/Users/dev/.codex"))
        XCTAssertNotEqual(accountB.id, "codex")
        XCTAssertFalse(accountA.allowsUnattributedHistory)
        XCTAssertFalse(accountB.allowsUnattributedHistory)
    }

    func testIncompleteDefaultLoginGetsOwnCardBesideSameWorkspaceSibling() async throws {
        let accountOnly = Fixtures.token(accountID: "A")
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "A", email: "", accessToken: accountOnly),
            "/Users/dev/.codex-b/auth.json": Fixtures.codexAuth(accountID: "A", email: "b@test"),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-b"]])

        XCTAssertEqual(assembly.codexCards.count, 2)
        let defaultCard = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "a|" })
        let sibling = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "a|b@test" })
        XCTAssertEqual(defaultCard.id, "codex")
        XCTAssertNotEqual(sibling.id, "codex")
        XCTAssertFalse(defaultCard.allowsUnattributedHistory)
        XCTAssertFalse(sibling.allowsUnattributedHistory)
    }

    func testEmailOnlySiblingHomeAppearsOnFirstAssemblyWithStableCardIDs() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "a@test"),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: nil, email: "b@test"),
        ])
        let defaults = makeScratchDefaults()
        let directories = ["/Users/dev": [".codex-work"]]

        let first = await assemble(files: files, directories: directories, defaults: defaults)

        XCTAssertEqual(first.codexCards.count, 2)
        let emailOnly = try XCTUnwrap(first.codexCards.first { $0.identity.accountID.isEmpty && $0.identity.email == "b@test" })
        XCTAssertFalse(emailOnly.allowsUnattributedHistory)

        let second = await assemble(files: files, directories: directories, defaults: defaults)

        XCTAssertEqual(second.codexCards.count, 2)
        XCTAssertEqual(Set(second.codexCards.map(\.id)), Set(first.codexCards.map(\.id)))
    }

    func testIncompletePiLoginDisablesUnattributedHistoryForASingleCard() async throws {
        let swap = #"{"schemaVersion":1,"mainHome":"/Users/dev/.codex","accounts":[{"number":1,"alias":"A","home":"/Users/dev/.xswap/a","identity":{"accountId":"ACCT-A","email":"alice@test"}}]}"#
        let files = FakeFiles([
            "/Users/dev/.xswap/accounts.json": swap,
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])
        let environment = ["XSWAP_HOME": "/Users/dev/.xswap"]

        let alone = await assemble(files: files, environment: environment)
        XCTAssertEqual(alone.codexCards.map(\.identity.key), ["acct-a|alice@test"])
        XCTAssertTrue(alone.codexCards[0].allowsUnattributedHistory)

        files.files["/Users/dev/.pi/agent/auth.json"] = Fixtures.piAuth([("openai-codex", "ACCT-B", "")])
        let withStranger = await assemble(files: files, environment: environment)

        XCTAssertEqual(withStranger.codexCards.map(\.identity.key), ["acct-a|alice@test"])
        XCTAssertFalse(withStranger.codexCards[0].allowsUnattributedHistory)
    }

    func testHomesAndPiMergeByWorkspaceAndUserIdentity() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-personal/auth.json": Fixtures.codexAuth(accountID: "ACCT-HOME", email: "me@home.test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([
                ("openai-codex", "ACCT-HOME", "me@home.test"),
                ("openai-codex-2", "ACCT-WORK", "me@work.test"),
            ]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work", ".codex-personal"]])

        XCTAssertEqual(assembly.codexCards.count, 2)
        let work = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-work|me@work.test" })
        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-home|me@home.test" })
        XCTAssertEqual(work.id, "codex")
        XCTAssertEqual(personal.id, ProviderAccountID.make(family: "codex", identityKey: "acct-home|me@home.test"))
        XCTAssertEqual(work.displayName, "Codex: work")
        XCTAssertEqual(work.authHomes, ["/Users/dev/.codex", "/Users/dev/.codex-work"])
        XCTAssertEqual(personal.authHomes, ["/Users/dev/.codex-personal"])
        XCTAssertEqual(work.piCredentialSources.map(\.providerID), ["openai-codex-2"])
        XCTAssertEqual(personal.piCredentialSources.map(\.providerID), ["openai-codex"])
        XCTAssertEqual(work.logHomes, ["/Users/dev/.codex", "/Users/dev/.codex-personal", "/Users/dev/.codex-work"])
        XCTAssertFalse(work.allowsUnattributedHistory)
        XCTAssertFalse(personal.allowsUnattributedHistory)
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-work|me@work.test")
        XCTAssertEqual(assembly.identityKeysByCard[personal.id], "acct-home|me@home.test")
    }

    func testUsersInTheSameWorkspaceRemainSeparateCards() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT", email: "a@example.test"),
            "/Users/dev/.codex-b/auth.json": Fixtures.codexAuth(accountID: "ACCT", email: "b@example.test"),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-b"]])

        XCTAssertEqual(assembly.codexCards.map(\.identity.key), ["acct|a@example.test", "acct|b@example.test"])
    }

    func testRegistryOrderAndBareCardOwnershipSurviveDefaultSwitch() async throws {
        let defaults = makeScratchDefaults()
        let work = Fixtures.codexAuth(accountID: "ACCT-WORK", email: "me@work.test")
        let personal = Fixtures.codexAuth(accountID: "ACCT-HOME", email: "me@home.test")
        let directories = ["/Users/dev": [".codex-personal"]]

        let first = await assemble(
            files: FakeFiles(["/Users/dev/.codex/auth.json": work, "/Users/dev/.codex-personal/auth.json": personal]),
            directories: directories, defaults: defaults
        )
        let personalID = try XCTUnwrap(first.codexCards.first { $0.identity.key == "acct-home|me@home.test" }?.id)

        let swapped = await assemble(
            files: FakeFiles(["/Users/dev/.codex/auth.json": personal, "/Users/dev/.codex-personal/auth.json": work]),
            directories: directories, defaults: defaults
        )

        XCTAssertEqual(swapped.codexCards.map(\.id), ["codex", personalID])
        XCTAssertEqual(swapped.identityKeysByCard["codex"], "acct-work|me@work.test")
        XCTAssertEqual(swapped.identityKeysByCard[personalID], "acct-home|me@home.test")
    }

    func testPiOnlyAccountGetsAReadOnlyCredentialSource() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex-2", "ACCT-HOME", "me@home.test")]),
        ])

        let assembly = await assemble(files: files)
        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-home|me@home.test" })
        XCTAssertTrue(personal.authHomes.isEmpty)
        XCTAssertEqual(personal.piCredentialSources.map(\.providerID), ["openai-codex-2"])

        let store = CodexAuthStore(
            files: files, keychain: FakeKeychain(), expectedIdentity: personal.identity,
            additionalAuthHomes: personal.authHomes, piCredentialSources: personal.piCredentialSources
        )
        let candidate = try XCTUnwrap(store.loadAuthCandidates().first)
        XCTAssertTrue(candidate.readOnly)
        XCTAssertNil(candidate.auth.tokens?.refreshToken)
        XCTAssertEqual(candidate.auth.tokens?.accountID, "acct-home")
    }

    func testCatalogKeepsMultiAccountLocalHistoryUnattributedAndPiReadOnly() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test"),
            "/Users/dev/.codex-b/auth.json": Fixtures.codexAuth(accountID: "B", email: "b@test"),
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([("openai-codex", "A", "a@test"), ("openai-codex-2", "B", "b@test")]),
        ])
        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-b"]])
        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
            .compactMap { $0 as? CodexProvider }

        XCTAssertEqual(providers.count, 2)
        XCTAssertTrue(providers.allSatisfy { !$0.allowsUnattributedHistory })
        XCTAssertEqual(providers.map { $0.authStore.piCredentialSources.count }, [1, 1])
    }

    // MARK: - Swap-managed homes

    func testSwapMainAndSavedHomesStayReadOnlyThroughRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = Fixtures.token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let credential = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":{"accountId":"A","email":"a@test"}}]}"#,
            "/test/main/auth.json": credential,
            "/test/saved/auth.json": credential,
        ])
        let environment = ["CODEX_HOME": "/test/main", "XSWAP_HOME": "/test/swap"]

        let assembly = await assemble(files: files, environment: environment, home: URL(fileURLWithPath: "/test"))
        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(card.authHomes, ["/test/main", "/test/saved"])

        let http = RoutingHTTPClient { _ in
            XCTFail("Read-only expired Swap credentials must not make requests")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let snapshot = await provider(for: card, files: files, environment: environment, now: now, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["/test/main/auth.json"], credential)
        XCTAssertEqual(files.files["/test/saved/auth.json"], credential)
    }

    func testSwapHomesStayReadOnlyWhenRegistryIdentityOmitsEmail() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = Fixtures.token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let credential = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":{"accountId":"A"}}]}"#,
            "/test/main/auth.json": credential,
            "/test/saved/auth.json": credential,
        ])
        let environment = ["CODEX_HOME": "/test/main", "XSWAP_HOME": "/test/swap"]

        let assembly = await assemble(files: files, environment: environment, home: URL(fileURLWithPath: "/test"))
        XCTAssertFalse(assembly.codexCards.isEmpty)

        let http = RoutingHTTPClient { _ in
            XCTFail("Swap-managed credentials must not rotate")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        for card in assembly.codexCards {
            _ = await provider(for: card, files: files, environment: environment, now: now, http: http).refresh()
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["/test/main/auth.json"], credential)
        XCTAssertEqual(files.files["/test/saved/auth.json"], credential)
    }
}
