import XCTest
@testable import OpenUsage

/// Codex account cards count the local history of the homes their account is signed in to.
@MainActor
final class CodexHistoryScopeTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private let now = Date()
    private var userHome: URL!
    private let a = CodexAccountIdentity(accountID: "A", email: "a@test")!
    private let b = CodexAccountIdentity(accountID: "B", email: "b@test")!

    override func setUpWithError() throws {
        userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: userHome)
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = userHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func rollout(input: Int, output: Int) -> String {
        CodexLogFixture.tokenCount(timestamp: OpenUsageISO8601.string(from: now),
                                   last: CodexLogFixture.usage(input: input, output: output), model: "gpt-5.2")
    }

    private func assemble(
        defaults: UserDefaults, environment: [String: String] = [:]
    ) async -> ProviderAccountAssembly {
        let home = userHome!
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment), files: LocalTextFileAccessor(),
            keychain: FakeKeychain(), homeDirectory: { home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["codex"]
        )
    }

    private func tokens(for card: CodexAccountCard, in assembly: ProviderAccountAssembly,
                        scanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>) async -> Int {
        let authStore = CodexAuthStore(environment: FakeEnvironment([:]), files: LocalTextFileAccessor(),
                                       keychain: FakeKeychain(), expectedIdentity: card.identity)
        let claims = assembly.codex.historyHomes.claims(for: card.identity, authStore: authStore)
        let scan = await CodexLogUsageScanner(incrementalScanner: scanner)
            .scan(homes: claims.logHomes, now: now, pricing: TestPricing.bundled)
        return scan?.series.daily.reduce(0) { $0 + $1.totalTokens } ?? 0
    }

    func testLoneCardKeepsItsHistoryWhenTheRegistryRemembersAnotherAccount() async throws {
        try write(".codex/auth.json", Fixtures.codexAuth(accountID: "A", email: "a@test"))
        try write(".codex/sessions/a.jsonl", rollout(input: 100, output: 50))
        let defaults = makeScratchDefaults()
        _ = ProviderAccountsStore(defaults: defaults).reconcile(with: [
            .init(family: "codex", identityKey: "b|b@test", label: "b@test",
                  sources: [.init(kind: .codexHome, anchor: "/gone", holdsDefaultSource: false)])
        ])

        let assembly = await assemble(defaults: defaults)

        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(assembly.codexCards.count, 1)
        let total = await tokens(for: card, in: assembly, scanner: IncrementalJSONLScanner())
        XCTAssertEqual(total, 150)
    }

    func testEachCardCountsOnlyTheHomeItIsSignedInToAndASwitchMovesIt() async throws {
        try write(".codex/auth.json", Fixtures.codexAuth(accountID: "A", email: "a@test"))
        try write(".codex/sessions/a.jsonl", rollout(input: 100, output: 50))
        try write(".codex-work/auth.json", Fixtures.codexAuth(accountID: "B", email: "b@test"))
        try write(".codex-work/sessions/b.jsonl", rollout(input: 20, output: 10))
        let assembly = await assemble(defaults: makeScratchDefaults())
        let cardA = try XCTUnwrap(assembly.codexCards.first { $0.identity == a })
        let cardB = try XCTUnwrap(assembly.codexCards.first { $0.identity == b })
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>()

        var totals = [await tokens(for: cardA, in: assembly, scanner: scanner),
                      await tokens(for: cardB, in: assembly, scanner: scanner)]
        XCTAssertEqual(totals, [150, 30])

        try write(".codex/auth.json", Fixtures.codexAuth(accountID: "B", email: "b@test"))
        totals = [await tokens(for: cardA, in: assembly, scanner: scanner),
                  await tokens(for: cardB, in: assembly, scanner: scanner)]
        XCTAssertEqual(totals, [0, 180])
    }

    func testSharedXswapHistoryCountsOnceWithTheMainHomesLogin() async throws {
        let main = userHome.appendingPathComponent(".codex").path
        let saved = userHome.appendingPathComponent("xswap/b").path
        try write("xswap-data/accounts.json", #"{"schemaVersion":1,"mainHome":"\#(main)","accounts":[{"number":1,"home":"\#(main)","identity":{"accountId":"A","email":"a@test"}},{"number":2,"home":"\#(saved)","shareHistory":true,"identity":{"accountId":"B","email":"b@test"}}]}"#)
        try write(".codex/auth.json", Fixtures.codexAuth(accountID: "A", email: "a@test"))
        try write(".codex/sessions/shared.jsonl", rollout(input: 100, output: 50))
        try write("xswap/b/auth.json", Fixtures.codexAuth(accountID: "B", email: "b@test"))
        try FileManager.default.createSymbolicLink(atPath: saved + "/sessions", withDestinationPath: main + "/sessions")
        let assembly = await assemble(
            defaults: makeScratchDefaults(),
            environment: ["XSWAP_HOME": userHome.appendingPathComponent("xswap-data").path]
        )
        let cardA = try XCTUnwrap(assembly.codexCards.first { $0.identity == a })
        let cardB = try XCTUnwrap(assembly.codexCards.first { $0.identity == b })
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>()

        let totals = [await tokens(for: cardA, in: assembly, scanner: scanner),
                      await tokens(for: cardB, in: assembly, scanner: scanner)]
        XCTAssertEqual(totals, [150, 0])
    }

    func testRegisteredXswapHomeWithoutAuthStillBelongsToItsAccount() throws {
        let saved = userHome.appendingPathComponent("xswap/b").path
        try write("xswap/b/sessions/b.jsonl", rollout(input: 20, output: 10))
        let homes = CodexHistoryHomes(homes: [saved], defaultHome: "/nonexistent", registeredOwners: [saved: b])

        XCTAssertEqual(homes.ownedHomes(by: b, files: LocalTextFileAccessor()), [saved])
    }

    func testKeychainLoginOwnsTheDefaultHomeAndItsOpenCodeHistory() {
        let homes = CodexHistoryHomes(homes: ["/Users/dev/.codex", "/Users/dev/.codex-old"],
                                      defaultHome: "/Users/dev/.codex", registeredOwners: [:])
        let authStore = CodexAuthStore(environment: FakeEnvironment([:]), files: FakeFiles([:]),
                                       keychain: FakeKeychain(Fixtures.codexAuth(accountID: "A", email: "a@test")),
                                       expectedIdentity: a)

        let claims = homes.claims(for: a, authStore: authStore)

        XCTAssertEqual(claims.logHomes.read.map(\.path), ["/Users/dev/.codex"])
        XCTAssertTrue(claims.ownsDefaultLogin)
    }

    func testAKeychainLoginNeverClaimsAnotherDefaultFolderOrOpenCode() {
        let homes = CodexHistoryHomes(homes: ["/Users/dev/.codex", "/Users/dev/.config/codex"],
                                      defaultHome: "/Users/dev/.codex", registeredOwners: [:])
        let files = FakeFiles(["/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test")])
        let keychain = FakeKeychain(Fixtures.codexAuth(accountID: "B", email: "b@test"))
        func claims(_ identity: CodexAccountIdentity) -> CodexHistoryClaims {
            homes.claims(for: identity, authStore: CodexAuthStore(
                environment: FakeEnvironment([:]), files: files, keychain: keychain, expectedIdentity: identity
            ))
        }

        XCTAssertEqual(claims(a).logHomes.read.map(\.path), ["/Users/dev/.codex"])
        XCTAssertTrue(claims(a).ownsDefaultLogin)
        XCTAssertEqual(claims(b).logHomes.read, [])
        XCTAssertFalse(claims(b).ownsDefaultLogin, "OpenCode history must land on exactly one card")
    }
}
