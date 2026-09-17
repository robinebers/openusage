import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeSwapReviewRegressionTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/swap-review-test")
    private let user = "11111111-1111-1111-1111-111111111111"
    private let organization = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private var swap: ClaudeSwapAccount {
        ClaudeSwapAccount(root: home.path + "/.claude-swap-backup", slot: "1",
            email: "saved@example.com", identityKey: "\(user)|\(organization)", organizationID: organization)
    }

    private func credentials(_ token: String, scope: String = "user:profile") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["\#(scope)"]}}"#
    }

    func testUUIDOnlyDefaultRemainsAvailableAlongsideSwap() async throws {
        // A UUID alone must not be guessed to belong to a saved organization, even for the same user.
        for defaultUser in [user, "22222222-2222-2222-2222-222222222222"] {
            let suite = "ClaudeSwapReview.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let files = FakeFiles([
                home.path + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"\#(defaultUser)","emailAddress":"default@example.com"}}"#,
                swap.root + "/sequence.json":
                    #"{"accounts":{"1":{"email":"saved@example.com","uuid":"\#(user)","organizationUuid":"\#(organization)"}}}"#,
                swap.sessionDirectory + "/.credentials.json": credentials("session")
            ])
            let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": credentials("default")])
            let observer = DefaultAccountObserver(environment: FakeEnvironment([:]), files: files,
                keychain: keychain, homeDirectory: { [home] in home })
            let accounts = ProviderAccountsStore(defaults: defaults)
            let first = await ProviderAccountAssembly.make(observer: observer, accountsStore: accounts)
            XCTAssertEqual(first.claudeCards.count, 2)
            let defaultCard = try XCTUnwrap(first.claudeCards.first { $0.identityKey == defaultUser })
            XCTAssertEqual(defaultCard.id, "claude")
            XCTAssertNil(defaultCard.organizationID)
            XCTAssertNil(defaultCard.swapAccount)
            XCTAssertFalse(defaultCard.usesDesktopCredentials)
            XCTAssertTrue(first.claudeCards.allSatisfy { !$0.allowsUnattributedPiUsage })
            XCTAssertEqual(first.identityKeysByCard[defaultCard.id], defaultUser)
            let repeated = await ProviderAccountAssembly.make(observer: observer, accountsStore: accounts)
            XCTAssertEqual(repeated.claudeCards, first.claudeCards)

            let providers = ProviderCatalog.make(defaults: defaults, claudeCards: first.claudeCards)
                .compactMap { $0 as? ClaudeProvider }
            XCTAssertEqual(providers.count, 2)
            XCTAssertEqual(Set(providers.map(\.provider.displayName)).count, 2)
            for runtime in providers {
                let configured = runtime.authStore
                let auth = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
                    desktopOrganization: configured.desktopOrganization,
                    expectedIdentityKey: configured.expectedIdentityKey, desktopOnly: configured.desktopOnly,
                    swapAccount: configured.swapAccount,
                    preferOrganizationScopedDesktop: configured.preferOrganizationScopedDesktop)
                let isDefault = runtime.provider.id == defaultCard.id
                XCTAssertEqual(auth.loadCredentialCandidates().map(\.oauth.accessToken),
                    [isDefault ? "default" : "session"])
                let provider = ClaudeProvider(authStore: auth)
                let available = await provider.hasLocalCredentials()
                XCTAssertTrue(available)
            }
        }
    }

    func testFullScopeSwapSessionSuppliesLiveUsageBeforeLimitedDefault() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)"}}"#,
            swap.sessionDirectory + "/.credentials.json": credentials("session")
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            "Claude Code-credentials": credentials("limited-default", scope: "user:inference")
        ])
        let auth = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
            swapAccount: swap)
        let generation = auth.credentialGeneration()
        let http = usageHTTP()
        let provider = ClaudeProvider(authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        let result = await provider.refresh()
        XCTAssertEqual(auth.loadCredentialCandidates().map(\.oauth.accessToken), ["session", "limited-default"])
        XCTAssertNil(result.warning)
        for (label, expected) in [("Session", 37.0), ("Weekly", 64.0)] {
            guard case let .progress(_, used, _, _, _, _, _, _) = result.line(label: label) else {
                XCTFail("Missing live \(label) limits")
                continue
            }
            XCTAssertEqual(used, expected)
        }
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer session" })
        XCTAssertEqual(auth.credentialGeneration(), generation)
    }

    func testFullScopeSwapSessionStillRejectsAnotherOrganization() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)"}}"#,
            swap.sessionDirectory + "/.credentials.json": credentials("session")
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            "Claude Code-credentials": credentials("limited-default", scope: "user:inference")
        ])
        let auth = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
            swapAccount: swap)
        let http = usageHTTP(profileOrganization: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let provider = ClaudeProvider(authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        let result = await provider.refresh()
        XCTAssertNil(result.line(label: "Session"))
        XCTAssertEqual(result.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
    }

    func testUUIDOnlyCardExcludesHistoryWhenMultipleAccountsAreKnown() async throws {
        let timestamp = "2026-02-20T12:00:00Z"
        let owned = #"{"ownerOrganizationUuid":"\#(organization)","ownerAccountUuid":"\#(user)"}"# + "\n" +
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: 100, output: 10)
        let fixtureHome = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "project/owned.jsonl": owned,
            "project/unowned.jsonl": ClaudeLogFixture.usageLine(timestamp: timestamp, input: 999,
                messageID: "unowned", requestID: "unowned")
        ])
        defer { try? FileManager.default.removeItem(at: fixtureHome) }
        let scanner = ClaudeLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { fixtureHome },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(), accountUUID: user,
            organizationUUID: nil, allowsUnattributedSessions: false)
        let result = await scanner.scan(now: Date(timeIntervalSince1970: 1_771_603_200), pricing: TestPricing.bundled)
        XCTAssertNil(result, "An unknown organization cannot claim the saved organization's history")
    }

    func testOnlyPrimaryCardAllowsUnattributedSessions() async throws {
        // Regression: every non-Desktop card was given allowsUnattributedSessions, so each swap card
        // claimed the same ~/.claude sessions, duplicating local spend across providers.
        let user2 = "22222222-2222-2222-2222-222222222222"
        let org2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let swapOnly = ClaudeSwapAccount(
            root: home.path + "/.claude-swap-backup", slot: "1",
            email: "swap@example.com", identityKey: "\(user2)|\(org2)", organizationID: org2
        )
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)"}}"#,
            swapOnly.root + "/sequence.json": """
                {"accounts":{"1":{"email":"swap@example.com","uuid":"\(user2)","organizationUuid":"\(org2)"}}}
                """
        ])
        let suite = "ClaudeSwapReview.Unattributed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = DefaultAccountObserver(environment: FakeEnvironment([:]), files: files,
            keychain: FakeKeychain(), homeDirectory: { [home] in home })
        let assembly = await ProviderAccountAssembly.make(observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults))

        XCTAssertEqual(assembly.claudeCards.count, 2)
        let primaryCard = try XCTUnwrap(assembly.claudeCards.first { $0.swapAccount == nil })
        let swapCard = try XCTUnwrap(assembly.claudeCards.first { $0.swapAccount != nil })
        XCTAssertFalse(primaryCard.usesDesktopCredentials)
        XCTAssertFalse(swapCard.usesDesktopCredentials)

        let providers = ProviderCatalog.make(defaults: defaults, claudeCards: assembly.claudeCards)
            .compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(providers.count, 2)
        let primaryProvider = try XCTUnwrap(providers.first { $0.provider.id == primaryCard.id })
        let swapProvider = try XCTUnwrap(providers.first { $0.provider.id == swapCard.id })
        XCTAssertTrue(primaryProvider.logUsageScanner.allowsUnattributedSessions,
                      "primary CLI card must claim unattributed ~/.claude sessions")
        XCTAssertFalse(swapProvider.logUsageScanner.allowsUnattributedSessions,
                       "swap-account card must not duplicate unattributed ~/.claude sessions")
    }

    private func usageHTTP(profileOrganization: String? = nil) -> RoutingHTTPClient {
        let expectedUser = user
        let profileOrganization = profileOrganization ?? organization
        return RoutingHTTPClient { request in
            if request.url.path == "/api/oauth/profile" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"account":{"uuid":"\#(expectedUser)"},"organization":{"uuid":"\#(profileOrganization)"}}"#.utf8))
            }
            XCTAssertEqual(request.url.path, "/api/oauth/usage")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"five_hour":{"utilization":37},"seven_day":{"utilization":64}}"#.utf8))
        }
    }
}
