import XCTest
@testable import OpenUsage

/// Whether discovery keeps the plain `codex` card or makes account cards, and what each receives.
@MainActor
final class CodexDiscoveryGateTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let piAuthPath = "/Users/dev/.pi/agent/auth.json"

    private func assemble(
        files: FakeFiles,
        directories: [String: [String]] = [:],
        environment: [String: String] = [:],
        keychain: String? = nil
    ) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: files,
            keychain: FakeKeychain(keychain),
            homeDirectory: { Fixtures.home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"],
            listCodexHomeDirectories: { directories[$0] ?? [] }
        )
    }

    /// The plain card exactly as `ProviderCatalog` builds it, on the test file system.
    private func plainProvider(_ discovery: CodexAccountDiscovery, files: FakeFiles, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(), now: { Self.now },
                additionalAuthHomes: discovery.plainAuthHomes,
                piCredentialSources: discovery.plainPiCredentialSources
            ),
            usageClient: CodexUsageClient(http: http),
            now: { Self.now }
        )
    }

    // MARK: - A lone account outside the configured home

    func testLonePiLoginFeedsThePlainCodexCard() async throws {
        let valid = Fixtures.token(accountID: "ACCT-A", email: "alice@test", exp: Self.now.addingTimeInterval(3600))
        let piAuth = #"{"openai-codex":{"type":"oauth","access":"\#(valid)","refresh":"pi-rt","accountId":"ACCT-A"}}"#
        let files = FakeFiles([piAuthPath: piAuth])

        let assembly = await assemble(files: files)

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.codex.plainPiCredentialSources, [.init(path: piAuthPath, providerID: "openai-codex")])
        XCTAssertTrue(assembly.codex.allowsUnattributedHistory)

        let http = RoutingHTTPClient { _ in Fixtures.usageResponse() }
        let provider = plainProvider(assembly.codex, files: files, http: http)
        let hasCredentials = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(hasCredentials)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer \(valid)")
        XCTAssertEqual(files.files[piAuthPath], piAuth, "pi's login is never rewritten")
    }

    func testLoneSiblingHomeFeedsThePlainCodexCard() async throws {
        let valid = Fixtures.token(accountID: "ACCT-A", email: "alice@test", exp: Self.now.addingTimeInterval(3600))
        let files = FakeFiles(["/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test", accessToken: valid)])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work"]])

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.codex.plainAuthHomes, ["/Users/dev/.codex-work"])

        let http = RoutingHTTPClient { _ in Fixtures.usageResponse() }
        let snapshot = await plainProvider(assembly.codex, files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer \(valid)")
    }

    func testLoneSiblingHomeIsScannedForThePlainCodexCardsSpend() async throws {
        let valid = Fixtures.token(accountID: "ACCT-A", email: "alice@test", exp: Self.now.addingTimeInterval(3600))
        let files = FakeFiles(["/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test", accessToken: valid)])
        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work"]])

        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
            .compactMap { $0 as? CodexProvider }
        let scanner = try XCTUnwrap(providers.first?.logUsageScanner)

        XCTAssertEqual(providers.map(\.provider.id), ["codex"])
        let homes = await scanner.codexHomes().map(\.path)
        XCTAssertTrue(homes.contains("/Users/dev/.codex-work"), "\(homes)")
    }

    func testLoneSiblingHomeStaysReadOnlyOnThePlainCodexCard() async throws {
        let expired = Fixtures.token(accountID: "ACCT-A", email: "alice@test", exp: Self.now.addingTimeInterval(-60))
        let credential = Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test", accessToken: expired)
        let files = FakeFiles(["/Users/dev/.codex-work/auth.json": credential])
        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-work"]])

        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let snapshot = await plainProvider(assembly.codex, files: files, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertFalse(http.requests.contains { $0.url.host == "auth.openai.com" })
        XCTAssertEqual(files.files["/Users/dev/.codex-work/auth.json"], credential)
    }

    // MARK: - The Keychain counts toward the second account

    func testKeychainLoginBesideAHomeLoginMakesTwoCardsOnAFreshInstall() async {
        let files = FakeFiles(["/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test")])

        let assembly = await assemble(files: files, keychain: Fixtures.codexAuth(accountID: "B", email: "b@test"))

        XCTAssertEqual(Set(assembly.codexCards.map(\.identity.key)), ["a|a@test", "b|b@test"])
        XCTAssertTrue(assembly.codexCards.allSatisfy { !$0.allowsUnattributedHistory })
    }

    func testKeychainLoginBesideAPiLoginMakesTwoCardsOnAFreshInstall() async throws {
        let files = FakeFiles([piAuthPath: Fixtures.piAuth([("openai-codex", "A", "a@test")])])

        let assembly = await assemble(files: files, keychain: Fixtures.codexAuth(accountID: "B", email: "b@test"))

        XCTAssertEqual(Set(assembly.codexCards.map(\.identity.key)), ["a|a@test", "b|b@test"])
        let piCard = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "a" })
        XCTAssertEqual(piCard.piCredentialSources, [.init(path: piAuthPath, providerID: "openai-codex")])
    }

    // MARK: - Logins that name no account at all

    func testTokenHomeWithoutAnyIdentityDisablesUnattributedHistory() async throws {
        let anonymous = Fixtures.codexAuth(accountID: nil, email: "", accessToken: Fixtures.token())
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test"),
            "/Users/dev/.codex-old/auth.json": anonymous,
        ])
        let directories = ["/Users/dev": [".codex-old"]]

        let plain = await assemble(files: files, directories: directories)
        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: plain.codex)
            .compactMap { $0 as? CodexProvider }

        XCTAssertTrue(plain.codexCards.isEmpty)
        XCTAssertEqual(providers.map(\.allowsUnattributedHistory), [false])

        files.files["/Users/dev/.xswap/accounts.json"] = #"{"schemaVersion":1,"mainHome":"/Users/dev/.codex","accounts":[{"number":1,"alias":"Personal","home":"/Users/dev/.xswap/a","identity":{"accountId":"A","email":"a@test"}}]}"#
        let cards = await assemble(files: files, directories: directories, environment: ["XSWAP_HOME": "/Users/dev/.xswap"])

        XCTAssertEqual(cards.codexCards.map(\.allowsUnattributedHistory), [false])
    }

    // MARK: - Labels

    func testPiLabelNamesASwapSlotThatHasNoAlias() async {
        let files = FakeFiles([
            "/Users/dev/.xswap/accounts.json": #"{"schemaVersion":1,"mainHome":"/Users/dev/.codex","accounts":[{"number":1,"home":"/Users/dev/.xswap/a","identity":{"accountId":"ACCT-A","email":"alice@test"}}]}"#,
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            piAuthPath: Fixtures.piAuth([("openai-codex", "ACCT-A", "alice@test")]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":1,"label":"Work"}]}"#,
        ])

        let assembly = await assemble(files: files, environment: ["XSWAP_HOME": "/Users/dev/.xswap"])

        XCTAssertEqual(assembly.codexCards.map(\.displayName), ["Codex: Work"])
    }
}
