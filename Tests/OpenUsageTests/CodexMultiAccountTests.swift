import XCTest
@testable import OpenUsage

@MainActor
final class CodexMultiAccountTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func b64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func token(accountID: String, email: String, exp: Date? = nil) -> String {
        var claims = """
        "https://api.openai.com/auth":{"chatgpt_account_id":"\(accountID)","chatgpt_plan_type":"pro"},
        "https://api.openai.com/profile":{"email":"\(email)"}
        """
        if let exp { claims += #","exp":\#(Int(exp.timeIntervalSince1970))"# }
        return "\(b64url(#"{"alg":"RS256"}"#)).\(b64url("{\(claims)}")).sig"
    }

    private func codexAuth(accountID: String?, email: String) -> String {
        let idToken = token(accountID: accountID ?? "unused", email: email)
        let account = accountID.map { #","account_id":"\#($0)""# } ?? ""
        return #"{"tokens":{"access_token":"at-\#(email)","refresh_token":"rt","id_token":"\#(idToken)"\#(account)}}"#
    }

    private func piAuth(_ entries: [(provider: String, accountID: String, email: String, expires: Int)]) -> String {
        let body = entries.map { entry in
            #""\#(entry.provider)":{"type":"oauth","access":"\#(token(accountID: entry.accountID, email: entry.email))","refresh":"rt","expires":\#(entry.expires),"accountId":"\#(entry.accountID)"}"#
        }.joined(separator: ",")
        return "{\(body)}"
    }

    private func makeDiscovery(
        environment: [String: String] = [:],
        files: [String: String],
        directories: [String: [String]] = [:]
    ) -> CodexAccountDiscovery {
        CodexAccountDiscovery(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            homeDirectory: { [home] in home },
            listDirectories: { directories[$0] ?? [] }
        )
    }

    private func errorBadge(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first(where: { $0.label == "Error" }) else {
            return nil
        }
        return text
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexMultiAccount.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }


    func testCandidateHomesCoverDefaultsEnvAndSiblingDirectories() {
        let discovery = makeDiscovery(
            environment: ["CODEX_HOME": "~/.codex, /opt/codex-ci"],
            files: [:],
            directories: [
                "/Users/dev": [".codex-work", ".codex-personal", ".config", "Documents"],
                "/Users/dev/.config": ["codex-ci", "codex", "gh"],
            ]
        )

        XCTAssertEqual(discovery.candidateHomes(), [
            "/Users/dev/.codex", "/opt/codex-ci", "/Users/dev/.config/codex",
            "/Users/dev/.codex-personal", "/Users/dev/.codex-work", "/Users/dev/.config/codex-ci",
        ])
    }

    func testHomeLoginsNameTheirAccountFromAccountIDOrIDTokenClaim() {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
                "/Users/dev/.codex-personal/auth.json": codexAuth(accountID: nil, email: "me@home.test"),
                "/Users/dev/.codex-apikey/auth.json": #"{"OPENAI_API_KEY":"sk-x"}"#,
            ],
            directories: ["/Users/dev": [".codex-personal", ".codex-apikey"]]
        )

        XCTAssertEqual(discovery.homeLogins(), [
            CodexHomeLogin(home: "/Users/dev/.codex", accountID: "acct-work", email: "me@work.test", planType: "pro"),
            CodexHomeLogin(home: "/Users/dev/.codex-personal", accountID: "unused", email: "me@home.test", planType: "pro"),
        ])
    }

    func testPiLoginsReadEveryCodexEntryWithMultiPassLabels() {
        let discovery = makeDiscovery(files: [
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex-2", "ACCT-WORK", "me@work.test", 1_800_000_000_000),
                ("openai-codex", "ACCT-HOME", "me@home.test", 1_700_000_000_000),
            ]) + "",
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ])

        let logins = discovery.piLogins()

        XCTAssertEqual(logins.map(\.providerID), ["openai-codex", "openai-codex-2"])
        XCTAssertEqual(logins.map(\.accountID), ["acct-home", "acct-work"])
        XCTAssertEqual(logins.map(\.label), [nil, "work"])
        XCTAssertEqual(logins.map(\.email), ["me@home.test", "me@work.test"])
        XCTAssertEqual(logins[1].expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testPiCodexProviderIDShape() {
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex"))
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex-2"))
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex-12"))
        XCTAssertFalse(CodexAccountDiscovery.isPiCodexProvider("openai-codex-"))
        XCTAssertFalse(CodexAccountDiscovery.isPiCodexProvider("openai-codex-work"))
        XCTAssertFalse(CodexAccountDiscovery.isPiCodexProvider("openai"))
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "openai-codex-3"), "codex")
    }


    private func assemble(
        files: [String: String],
        directories: [String: [String]] = [:],
        keychainValue: String? = nil,
        defaults: UserDefaults? = nil
    ) -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: FakeKeychain(keychainValue),
            homeDirectory: { [home] in home }
        )
        return ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults ?? makeScratchDefaults()),
            families: ["codex"],
            codexDiscovery: makeDiscovery(files: files, directories: directories)
        )
    }

    func testTwoAccountsAcrossHomesAndPiBecomeTwoCardsMergedByIdentity() throws {
        let files = [
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-work/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-personal/auth.json": codexAuth(accountID: "ACCT-HOME", email: "me@home.test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex", "ACCT-HOME", "me@home.test", 1_800_000_000_000),
                ("openai-codex-2", "ACCT-WORK", "me@work.test", 1_800_000_000_000),
            ]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ]
        let assembly = assemble(files: files, directories: ["/Users/dev": [".codex-work", ".codex-personal"]])

        XCTAssertEqual(assembly.codexCards.count, 2)
        let work = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "acct-work" })
        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "acct-home" })

        XCTAssertEqual(work.id, "codex")
        XCTAssertEqual(personal.id, ProviderAccountID.make(family: "codex", identityKey: "acct-home"))
        XCTAssertEqual(work.displayName, "Codex: work")
        XCTAssertEqual(personal.displayName, "Codex: me@home.test")
        XCTAssertEqual(work.authPaths, ["/Users/dev/.codex/auth.json", "/Users/dev/.codex-work/auth.json"])
        XCTAssertEqual(work.logHomes, ["/Users/dev/.codex", "/Users/dev/.codex-work"])
        XCTAssertEqual(personal.logHomes, ["/Users/dev/.codex-personal"])
        XCTAssertEqual(work.piProviderIDs, ["openai-codex-2"])
        XCTAssertEqual(personal.piProviderIDs, ["openai-codex"])
        XCTAssertTrue(work.ownsUnattributedSources)
        XCTAssertFalse(personal.ownsUnattributedSources)
        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "acct-work", personal.id: "acct-home"])
    }

    func testSingleAccountStaysPlainCodexCard() {
        let assembly = assemble(files: [
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-1", email: "me@work.test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([("openai-codex", "ACCT-1", "me@work.test", 1_800_000_000_000)]),
        ])

        XCTAssertEqual(assembly.codexCards.map(\.id), ["codex"])
        XCTAssertEqual(assembly.codexCards.first?.displayName, "Codex")
        XCTAssertEqual(assembly.codexCards.first?.piProviderIDs, ["openai-codex"])
        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "acct-1"])
    }

    func testPiOnlyAccountBecomesACardWithoutHomeCredentials() throws {
        let assembly = assemble(files: [
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([("openai-codex-2", "ACCT-HOME", "me@home.test", 1_800_000_000_000)]),
        ])

        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "acct-home" })
        XCTAssertTrue(personal.authPaths.isEmpty)
        XCTAssertTrue(personal.logHomes.isEmpty)
        XCTAssertEqual(personal.piLogin?.providerID, "openai-codex-2")
        XCTAssertEqual(personal.displayName, "Codex: me@home.test")
    }

    func testKeychainCredentialLeavesTheFamilyUnscoped() {
        let assembly = assemble(
            files: [
                "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
                "/Users/dev/.codex-personal/auth.json": codexAuth(accountID: "ACCT-HOME", email: "me@home.test"),
            ],
            directories: ["/Users/dev": [".codex-personal"]],
            keychainValue: #"{"tokens":{"access_token":"kc"}}"#
        )

        XCTAssertTrue(assembly.codexCards.isEmpty, "an unresolved identity must not scope the Codex card")
        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
    }

    func testCardIDsSurviveADefaultHomeSwap() throws {
        let defaults = makeScratchDefaults()
        let work = codexAuth(accountID: "ACCT-WORK", email: "me@work.test")
        let personal = codexAuth(accountID: "ACCT-HOME", email: "me@home.test")
        let directories = ["/Users/dev": [".codex-personal"]]

        let first = assemble(
            files: ["/Users/dev/.codex/auth.json": work, "/Users/dev/.codex-personal/auth.json": personal],
            directories: directories, defaults: defaults
        )
        let personalID = try XCTUnwrap(first.codexCards.first { $0.identityKey == "acct-home" }).id

        let swapped = assemble(
            files: ["/Users/dev/.codex/auth.json": personal, "/Users/dev/.codex-personal/auth.json": work],
            directories: directories, defaults: defaults
        )

        XCTAssertEqual(swapped.codexCards.first { $0.identityKey == "acct-home" }?.id, personalID)
        XCTAssertEqual(swapped.codexCards.first { $0.identityKey == "acct-work" }?.id, "codex")
        XCTAssertTrue(try XCTUnwrap(swapped.codexCards.first { $0.identityKey == "acct-home" }).ownsUnattributedSources)
    }

    func testCatalogBuildsOneScopedProviderPerCard() {
        let assembly = assemble(
            files: [
                "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
                "/Users/dev/.codex-personal/auth.json": codexAuth(accountID: "ACCT-HOME", email: "me@home.test"),
            ],
            directories: ["/Users/dev": [".codex-personal"]]
        )

        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codexCards: assembly.codexCards)
        let codex = providers.compactMap { $0 as? CodexProvider }

        XCTAssertEqual(codex.map(\.provider.id), assembly.codexCards.map(\.id))
        XCTAssertEqual(codex.map(\.provider.displayName), ["Codex: me@work.test", "Codex: me@home.test"])
        XCTAssertEqual(codex[1].authStore.explicitAuthPaths, ["/Users/dev/.codex-personal/auth.json"])
        XCTAssertFalse(codex[1].authStore.includesKeychain)
        XCTAssertFalse(codex[1].includesOpenCodeUsage)
        XCTAssertTrue(codex[1].widgetDescriptors.allSatisfy { $0.id.hasPrefix("\(codex[1].provider.id).") })
    }

    func testDefaultLayoutTranslatesToExtraCodexCards() {
        let translate = DefaultLayout.translatedForAccountCards(providerIDs: ["claude", "codex", "codex@ab12cd34", "cursor"])

        XCTAssertEqual(
            translate(["codex.session", "cursor.auto", "claude.weekly"]),
            ["codex.session", "codex@ab12cd34.session", "cursor.auto", "claude.weekly"]
        )
    }


    func testExpiredPiTokenAsksToRefreshInPiWithoutTouchingTheNetwork() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let login = PiCodexLogin(
            providerID: "openai-codex-2", accountID: "acct-home", email: nil, planType: nil, label: nil,
            accessToken: token(accountID: "acct-home", email: "me@home.test"),
            expiresAt: now.addingTimeInterval(-60)
        )
        let provider = CodexProvider(
            provider: CodexProvider.makeProvider(id: "codex@1", displayName: "Codex: home"),
            authStore: CodexAuthStore(files: FakeFiles(), keychain: FakeKeychain(), now: { now },
                                      explicitAuthPaths: [], includesKeychain: false, piLogin: login),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorBadge(snapshot), CodexAuthError.piTokenExpired.errorDescription)
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRejectedPiTokenIsNeverRefreshed() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let login = PiCodexLogin(
            providerID: "openai-codex-2", accountID: "acct-home", email: nil, planType: nil, label: nil,
            accessToken: token(accountID: "acct-home", email: "me@home.test", exp: now.addingTimeInterval(3600)),
            expiresAt: now.addingTimeInterval(3600)
        )
        let provider = CodexProvider(
            provider: CodexProvider.makeProvider(id: "codex@1", displayName: "Codex: home"),
            authStore: CodexAuthStore(files: FakeFiles(), keychain: FakeKeychain(), now: { now },
                                      explicitAuthPaths: [], includesKeychain: false, piLogin: login),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorBadge(snapshot), CodexAuthError.piTokenExpired.errorDescription)
        XCTAssertEqual(http.requests.count, 1, "one usage attempt, no token-refresh call")
        XCTAssertEqual(http.requests.first?.headers["ChatGPT-Account-Id"], "acct-home")
    }

    func testPiSpendSplitsByPiProviderID() {
        let since = Date(timeIntervalSince1970: 0)
        let tokens = TokenBreakdown(input: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 5)
        let entries = [
            PiUsageScanner.Entry(id: "a", timestamp: Date(timeIntervalSince1970: 1_800_000_000), cardID: "codex",
                                 piProviderID: "openai-codex", model: "gpt-5", carriedCost: 1, tokens: tokens, reportedTotalTokens: 15),
            PiUsageScanner.Entry(id: "b", timestamp: Date(timeIntervalSince1970: 1_800_000_000), cardID: "codex",
                                 piProviderID: "openai-codex-2", model: "gpt-5", carriedCost: 2, tokens: tokens, reportedTotalTokens: 15),
        ]
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:]))

        let all = PiUsageScanner.aggregate(entries: entries, cardID: "codex", since: since, pricing: pricing)
        let second = PiUsageScanner.aggregate(entries: entries, cardID: "codex", piProviderIDs: ["openai-codex-2"], since: since, pricing: pricing)

        XCTAssertEqual(all.series.daily.first?.costUSD, 3)
        XCTAssertEqual(second.series.daily.first?.costUSD, 2)
    }
}
