import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeSwapAccountTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/swap-test")
    private let user = "11111111-1111-1111-1111-111111111111"
    private let org = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private var account: ClaudeSwapAccount {
        ClaudeSwapAccount(root: home.path + "/.claude-swap-backup", slot: "2", email: "work@example.com",
                          identityKey: "\(user)|\(org)", organizationID: org)
    }

    private func credentials(_ access: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"refresh","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
    }

    func testDiscoversThreeAccountsAndDeduplicatesDefaultLogin() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json": #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(org)"}}"#,
            account.root + "/sequence.json": #"""
            {"accounts":{
              "2":{"email":"work@example.com","uuid":"11111111-1111-1111-1111-111111111111","organizationUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
              "1":{"email":"first@example.com","uuid":"22222222-2222-2222-2222-222222222222","organizationUuid":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},
              "3":{"email":"second@example.com","uuid":"33333333-3333-3333-3333-333333333333","organizationUuid":"cccccccc-cccc-cccc-cccc-cccccccccccc"}
            }}
            """#
        ])
        let suite = "ClaudeSwapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(environment: FakeEnvironment([:]), files: files,
                                              keychain: FakeKeychain(), homeDirectory: { [home] in home })
        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.claudeCards.count, 3)
        XCTAssertEqual(Set(assembly.claudeCards.map(\.displayName)), [
            "Claude: Organization (work@example.com)",
            "Claude: Organization bbbbbbbb (first@example.com)",
            "Claude: Organization cccccccc (second@example.com)"
        ])
        XCTAssertEqual(assembly.identityKeysByCard.count, 3)
        XCTAssertTrue(assembly.claudeCards.allSatisfy { !$0.allowsUnattributedPiUsage })
        XCTAssertTrue(assembly.claudeCards.allSatisfy { $0.additionalLogDirectories.count == 3 })
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.sources.map(\.kind), [.defaultHome, .claudeSwap])
        let again = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)
        XCTAssertEqual(assembly.claudeCards, again.claudeCards)
        let providers = ProviderCatalog.make(defaults: defaults, claudeCards: assembly.claudeCards)
            .compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(providers.filter { $0.authStore.swapAccount != nil }.count, 3)
    }

    func testMalformedSlotsDoNotHideValidSlotsOrEscapeTheVault() {
        let files = FakeFiles([account.root + "/sequence.json": #"""
        {"accounts":{
          "../1":{"email":"bad@example.com","uuid":"11111111-1111-1111-1111-111111111111","organizationUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
          "2":{"email":"work@example.com","uuid":"11111111-1111-1111-1111-111111111111","organizationUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
          "3":{"email":"missing-identity@example.com"}
        }}
        """# ])
        XCTAssertEqual(ClaudeSwapAccount.discover(files: files, home: home), [account])
        XCTAssertEqual(account.sessionDirectory, account.root + "/sessions/2-work_example.com")
    }

    func testSessionCredentialsCannotFallBackToDefaultOrEnvironmentLogin() throws {
        let files = FakeFiles([account.sessionDirectory + "/.credentials.json": credentials("session")])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": credentials("wrong-account")])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "wrong-env", "CLAUDE_CONFIG_DIR": "/wrong"]),
            files: files, keychain: keychain, expectedIdentityKey: account.identityKey, swapAccount: account
        )
        XCTAssertEqual(store.keychainServiceCandidates().count, 1)
        XCTAssertFalse(store.keychainServiceCandidates().contains("Claude Code-credentials"))
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        XCTAssertEqual(state.oauth.accessToken, "session")
        let generation = store.credentialGeneration()
        state.oauth.accessToken = "rotated"
        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        XCTAssertTrue(files.files[account.sessionDirectory + "/.credentials.json"]?.contains("rotated") == true)
        XCTAssertEqual(keychain.currentUserValues["Claude Code-credentials"], credentials("wrong-account"))
        files.files.removeAll()
        XCTAssertTrue(store.loadCredentialCandidates().isEmpty)
    }

    func testVaultUsesExplicitSlotAndNeverRotatesBackupTokens() async throws {
        let keychain = SwapKeychain(value: credentials("vault"))
        let store = ClaudeAuthStore(environment: FakeEnvironment([:]), files: FakeFiles([:]),
                                    keychain: keychain, expectedIdentityKey: account.identityKey, swapAccount: account)
        let state = try XCTUnwrap(store.loadCredentialCandidates().first)
        XCTAssertEqual(state.source, .swapVault)
        XCTAssertNil(state.oauth.refreshToken)
        XCTAssertEqual(keychain.lastAccount, "account-2-work@example.com")
        XCTAssertFalse(try store.save(state, ifUnchanged: store.credentialGeneration()))
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url.path, "/api/oauth/profile")
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(authStore: store, usageClient: ClaudeUsageClient(httpClient: http),
                                      logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        let result = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1)
        if case let .badge(_, message, _, _)? = result.line(label: "Error") {
            XCTAssertEqual(message, ClaudeAuthError.swapTokenExpired.localizedDescription)
        } else { XCTFail("Expected guidance to renew the saved Swap account") }
    }

    func testBase64VaultFileTakesPrecedenceOverKeychain() throws {
        let path = account.root + "/credentials/.creds-2-work@example.com.enc"
        let files = FakeFiles([path: Data(credentials("file").utf8).base64EncodedString()])
        let keychain = SwapKeychain(value: credentials("keychain"))
        let store = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain, swapAccount: account)
        XCTAssertEqual(store.loadCredentialCandidates().first?.oauth.accessToken, "file")
        XCTAssertNil(keychain.lastAccount)
        files.files[path] = "invalid base64"
        XCTAssertEqual(store.loadCredentialCandidates().first?.oauth.accessToken, "keychain")
    }

    func testDefaultSourceIsUsedOnlyWhileItNamesTheSameAccount() {
        let files = FakeFiles([
            home.path + "/.claude.json": #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(org)"}}"#,
            account.sessionDirectory + "/.credentials.json": credentials("session")
        ])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": credentials("default")])
        let store = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
                                    expectedIdentityKey: account.identityKey, swapAccount: account)
        XCTAssertEqual(store.loadCredentialCandidates().map(\.oauth.accessToken), ["default", "session"])
        let generation = store.credentialGeneration()
        files.files[home.path + "/.claude.json"] = #"{"oauthAccount":{"accountUuid":"different","organizationUuid":"other"}}"#
        XCTAssertEqual(store.loadCredentialCandidates().map(\.oauth.accessToken), ["session"])
        XCTAssertNotEqual(store.credentialGeneration(), generation)
    }

    func testLaunchingFromSwapSessionDoesNotDuplicateItsCredentials() throws {
        let path = account.sessionDirectory + "/.credentials.json"
        let files = FakeFiles([
            account.sessionDirectory + "/.claude.json": #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(org)"}}"#,
            path: credentials("session")
        ])
        let store = ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": account.sessionDirectory]),
                                    files: files, keychain: FakeKeychain(), swapAccount: account)
        XCTAssertEqual(store.expectedIdentityKey, account.identityKey)
        XCTAssertEqual(store.loadCredentialCandidates().count, 1)
        let generation = store.credentialGeneration()
        var rotated = try XCTUnwrap(store.loadCredentialCandidates().first)
        rotated.oauth.accessToken = "new-session"
        XCTAssertTrue(try store.save(rotated, ifUnchanged: generation))
        XCTAssertEqual(store.credentialGeneration(), generation.replacing(rotated))
    }

    func testAdditionalSessionHistoryIsFilteredAndSharedHistoryIsDeduplicated() async throws {
        let timestamp = "2026-02-20T12:00:00Z"
        let owned = #"{"ownerOrganizationUuid":"org-a","ownerAccountUuid":"user-a"}"# + "\n" +
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: 100, output: 10)
        let otherOwned = #"{"ownerOrganizationUuid":"org-b","ownerAccountUuid":"user-b"}"# + "\n" +
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: 999, messageID: "other", requestID: "other")
        let sharedHome = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "project/shared.jsonl": owned, "project/other.jsonl": otherOwned
        ])
        let session = try ClaudeLogFixture.makeHome(files: [
            "project/shared.jsonl": owned,
            "project/other.jsonl": otherOwned,
            "project/unowned.jsonl": ClaudeLogFixture.usageLine(timestamp: timestamp, input: 999,
                                                                messageID: "unowned", requestID: "unowned")
        ])
        defer {
            try? FileManager.default.removeItem(at: sharedHome)
            try? FileManager.default.removeItem(at: session)
        }
        for (user, org, expected) in [("user-a", "org-a", 110), ("user-b", "org-b", 999)] {
            let scanner = ClaudeLogUsageScanner(
                environment: FakeEnvironment([:]), homeDirectory: { sharedHome },
                incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
                accountUUID: user, organizationUUID: org, additionalConfigDirectories: [session.path]
            )
            let result = await scanner.scan(now: Date(timeIntervalSince1970: 1_771_603_200), pricing: TestPricing.bundled)
            XCTAssertEqual(result?.series.daily.reduce(0) { $0 + $1.totalTokens }, expected)
        }
    }
}

private final class SwapKeychain: KeychainAccessing, @unchecked Sendable {
    let value: String
    var lastAccount: String?
    init(value: String) { self.value = value }
    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("Unexpected vault write") }
    func readGenericPassword(service: String, account: String) throws -> String? {
        XCTAssertEqual(service, "claude-swap")
        lastAccount = account
        return value
    }
}
