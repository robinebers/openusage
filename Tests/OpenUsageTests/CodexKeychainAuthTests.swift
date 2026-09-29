import XCTest
@testable import OpenUsage

@MainActor
final class CodexKeychainAuthTests: XCTestCase {
    private let home = "/openusage-keychain-fixture/codex-home"
    private let account = "cli|d702dafc32309bab"
    private let otherAccount = "cli|0000000000000000"

    func testAccountMatchesCodexSHA256FormatAndMissingPathFallback() {
        XCTAssertEqual(CodexAuthStore.keychainAccount(codexHome: home), account)
        // A failed canonicalization keeps the original path, including its unresolved components.
        XCTAssertEqual(CodexAuthStore.keychainAccount(codexHome: home + "/../missing"),
                       "cli|d5a7cc6be970c406")
    }

    func testAccountResolvesSymlinksBeforeHashing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("codex-home")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertEqual(CodexAuthStore.keychainAccount(codexHome: target.path),
                       CodexAuthStore.keychainAccount(codexHome: alias.path + "/."))
    }

    func testSelectsConfiguredHomeAmongMultipleKeychainAccounts() throws {
        let keychain = AccountKeychain(values: [
            otherAccount: credential("unrelated"), account: credential("selected")
        ])
        let state = try XCTUnwrap(store(keychain).loadKeychainAuth())

        XCTAssertEqual(state.auth.tokens?.accessToken, "selected")
        XCTAssertEqual(state.source, .keychain(account: account))
        XCTAssertEqual(keychain.readAccounts, [account])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testMissingConfiguredHomeDoesNotReadAnotherAccount() {
        let keychain = AccountKeychain(values: [otherAccount: credential("unrelated")])
        XCTAssertNil(store(keychain).loadKeychainAuth())
        XCTAssertEqual(keychain.readAccounts, [account])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testDefaultKeychainHomeIsCodexNotLegacyConfigDirectory() throws {
        let defaultAccount = CodexAuthStore.keychainAccount(codexHome: "~/.codex")
        let keychain = AccountKeychain(values: [defaultAccount: credential("default")])
        let authStore = CodexAuthStore(environment: FakeEnvironment([:]), files: FakeFiles(), keychain: keychain)

        XCTAssertEqual(authStore.authPaths(), ["~/.config/codex/auth.json", "~/.codex/auth.json"])
        XCTAssertEqual(try XCTUnwrap(authStore.loadKeychainAuth()).source, .keychain(account: defaultAccount))
        XCTAssertEqual(keychain.readAccounts, [defaultAccount])
    }

    func testSaveAndReloadRetainOriginalAccountAfterHomeChanges() async throws {
        let unrelated = credential("unrelated")
        let keychain = AccountKeychain(values: [otherAccount: unrelated, account: credential("original")])
        var authStore = store(keychain)
        var state = try XCTUnwrap(authStore.loadKeychainAuth())
        authStore.environment = FakeEnvironment(["CODEX_HOME": "/another/codex-home"])

        let current = await authStore.isCurrent(state)
        XCTAssertTrue(current)
        state.auth.tokens?.accessToken = "rotated"
        state.auth.tokens?.refreshToken = "rotated-refresh"
        try authStore.save(state)

        XCTAssertEqual(keychain.writeAccounts, [account])
        XCTAssertEqual(keychain.values[otherAccount], unrelated)
        let reloaded = try XCTUnwrap(authStore.loadKeychainAuth(account: account))
        XCTAssertEqual(reloaded.auth.tokens?.accessToken, "rotated")
        XCTAssertEqual(reloaded.auth.tokens?.refreshToken, "rotated-refresh")
        XCTAssertEqual(reloaded.source, state.source)
    }

    func testFileSaveNeverWritesKeychain() throws {
        let path = home + "/auth.json"
        let files = FakeFiles([path: credential("file")])
        let keychain = AccountKeychain(values: [account: credential("keychain")])
        let authStore = store(keychain, files: files)
        var state = try XCTUnwrap(authStore.loadAuth(at: path))
        state.auth.tokens?.accessToken = "rotated-file"
        try authStore.save(state)

        XCTAssertEqual(CodexAuthStore.parseAuth(try XCTUnwrap(files.files[path]))?.tokens?.accessToken, "rotated-file")
        XCTAssertTrue(keychain.writeAccounts.isEmpty)
        XCTAssertTrue(keychain.readAccounts.isEmpty)
    }

    func testSwapScopedKeychainRemainsReadOnly() throws {
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "workspace", email: "test@example.com"))
        let original = CodexSwapAccountTests.credential(identity, token: "read-only")
        let keychain = AccountKeychain(values: [account: original])
        var authStore = store(keychain)
        authStore.expectedIdentity = identity
        let state = try XCTUnwrap(authStore.loadKeychainAuth())

        XCTAssertTrue(state.readOnly)
        XCTAssertNil(state.auth.tokens?.refreshToken)
        XCTAssertThrowsError(try authStore.save(state)) { error in
            XCTAssertEqual(error as? CodexAuthError, .tokenConflict)
        }
        XCTAssertEqual(keychain.values[account], original)
        XCTAssertTrue(keychain.writeAccounts.isEmpty)
    }

    func testRefreshPersistsOnlySelectedKeychainItemForNextLoad() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = #"{"tokens":{"access_token":"old","refresh_token":"old-refresh"},"last_refresh":"2000-01-01T00:00:00Z"}"#
        let unrelated = credential("unrelated")
        let keychain = AccountKeychain(values: [account: old, otherAccount: unrelated])
        let authStore = store(keychain, now: now)
        let http = RoutingHTTPClient { request in
            if request.url.host == "auth.openai.com" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"rotated","refresh_token":"rotated-refresh"}"#.utf8
                ))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = await provider(authStore, http: http, now: now).refresh()

        XCTAssertEqual(keychain.writeAccounts, [account])
        XCTAssertEqual(keychain.values[otherAccount], unrelated)
        let reloaded = try XCTUnwrap(store(keychain, now: now).loadKeychainAuth())
        XCTAssertEqual(reloaded.auth.tokens?.accessToken, "rotated")
        XCTAssertEqual(reloaded.auth.tokens?.refreshToken, "rotated-refresh")
        XCTAssertFalse(authStore.needsRefresh(reloaded.auth))
        XCTAssertEqual(http.requests.filter { $0.url.host == "auth.openai.com" }.count, 1)
    }

    func testFileFirstRefreshDoesNotReadKeychain() async {
        let files = FakeFiles([home + "/auth.json": credential("file")])
        let keychain = AccountKeychain(values: [account: credential("keychain")])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer file")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = await provider(store(keychain, files: files, now: now), http: http, now: now).refresh()

        XCTAssertTrue(keychain.readAccounts.isEmpty)
        XCTAssertTrue(keychain.writeAccounts.isEmpty)
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
        XCTAssertEqual(http.requests.count, 2, "The file login should fetch usage and reset credits")
    }

    private func credential(_ token: String) -> String {
        #"{"tokens":{"access_token":"\#(token)"}}"#
    }

    private func store(_ keychain: AccountKeychain, files: FakeFiles = FakeFiles(), now: Date = Date()) -> CodexAuthStore {
        CodexAuthStore(environment: FakeEnvironment(["CODEX_HOME": home]), files: files,
                       keychain: keychain, now: { now })
    }

    private func provider(_ authStore: CodexAuthStore, http: RoutingHTTPClient, now: Date) -> CodexProvider {
        CodexProvider(authStore: authStore, usageClient: CodexUsageClient(http: http),
                      logUsageScanner: CodexLogFixture.scanner(home: nil),
                      allowsUnattributedHistory: false, now: { now }, pricing: { TestPricing.bundled })
    }
}

/// Synthetic items sharing a service, keyed by account. No test invokes the real Keychain.
private final class AccountKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String]
    var readAccounts: [String] = []
    var writeAccounts: [String] = []
    var serviceOnlyReads = 0

    init(values: [String: String]) { self.values = values }

    func readGenericPassword(service: String) throws -> String? {
        serviceOnlyReads += 1
        XCTFail("Codex must not select the first item for a service")
        return values.values.first
    }

    func writeGenericPassword(service: String, value: String) throws {
        XCTFail("Codex must not write without an account")
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        XCTAssertEqual(service, CodexAuthStore.keychainService)
        readAccounts.append(account)
        return values[account]
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        XCTAssertEqual(service, CodexAuthStore.keychainService)
        writeAccounts.append(account)
        values[account] = value
    }
}
