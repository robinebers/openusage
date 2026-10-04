import XCTest
@testable import OpenUsage

/// Finding Codex logins on disk — Codex homes, pi's auth.json — and loading them read-only.
@MainActor
final class CodexHomeDiscoveryTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private let home = Fixtures.home

    private func scanner(
        environment: [String: String] = [:],
        files: FakeFiles,
        directories: [String: [String]] = [:]
    ) -> CodexHomeScanner {
        CodexHomeScanner(
            environment: FakeEnvironment(environment),
            files: files,
            homeDirectory: { [home] in home },
            listDirectories: { directories[$0] ?? [] }
        )
    }

    private func piScanner(files: FakeFiles) -> PiCodexLoginScanner {
        PiCodexLoginScanner(environment: FakeEnvironment(), files: files, homeDirectory: { [home] in home })
    }

    func testCandidateHomesTreatConfiguredCommaPathAsSingleHomeAndKeepSiblingDirectories() {
        let scanner = scanner(
            environment: ["CODEX_HOME": "  ~/custom,codex  "],
            files: FakeFiles(),
            directories: [
                "/Users/dev": [".codex-work", ".codex-personal", ".config", "Documents"],
                "/Users/dev/.config": ["codex-ci", "codex", "gh"],
            ]
        )

        XCTAssertEqual(scanner.candidateHomes(), [
            "/Users/dev/custom,codex", "/Users/dev/.config/codex", "/Users/dev/.codex",
            "/Users/dev/.codex-personal", "/Users/dev/.codex-work", "/Users/dev/.config/codex-ci",
        ])
    }

    func testSiblingDiscoveryIncludesHiddenCodexDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex-work"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent(".codex-file"))

        let names = CodexHomeScanner.listSubdirectories(root.path)

        XCTAssertTrue(names.contains(".codex-work"))
        XCTAssertFalse(names.contains(".codex-file"))
    }

    func testHomeLoginsSkipHomesWithoutAnIdentityAndDeduplicateSwapMainHome() {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "a@test"),
            "/Users/dev/.codex-work/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "b@test"),
            "/Users/dev/.codex-apikey/auth.json": #"{"OPENAI_API_KEY":"sk-test"}"#,
        ])

        let logins = scanner(files: files, directories: ["/Users/dev": [".codex-work", ".codex-apikey"]])
            .logins(additionalHomes: ["~/.codex/"])

        XCTAssertEqual(logins.map(\.home), ["/Users/dev/.codex", "/Users/dev/.codex-work"])
        XCTAssertEqual(logins.map(\.identity.key), ["acct-a|a@test", "acct-b|b@test"])
    }

    func testIdentityFallsBackFromIncompleteIDTokenToAccessToken() throws {
        let auth = try XCTUnwrap(CodexAuthStore.parseAuth(Fixtures.codexAuth(
            accountID: nil, email: "ME@WORK.TEST", accessAccountID: "ACCT-WORK"
        )))

        XCTAssertEqual(CodexAccountIdentity(auth: auth)?.key, "acct-work|me@work.test")
    }

    func testPiDiscoveryKeepsEveryMatchingIdentityWithoutSnapshottingTokens() {
        let files = FakeFiles([
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([
                ("openai-codex-2", "ACCT-WORK", "me@work.test"),
                ("openai-codex", "ACCT-HOME", "me@home.test"),
            ]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ])

        let scan = piScanner(files: files).scan()

        XCTAssertEqual(scan.logins.map(\.providerID), ["openai-codex", "openai-codex-2"])
        XCTAssertEqual(scan.logins.map(\.identity.key), ["acct-home|me@home.test", "acct-work|me@work.test"])
        XCTAssertEqual(scan.logins.map(\.label), [nil, "work"])
        XCTAssertEqual(Set(scan.logins.map(\.authPath)), ["/Users/dev/.pi/agent/auth.json"])
    }

    func testPiDiscoverySkipsLoginsThatCannotNameTheirAccount() {
        let files = FakeFiles([
            "/Users/dev/.pi/agent/auth.json": Fixtures.piAuth([
                ("openai-codex", "ACCT-HOME", "me@home.test"),
                ("openai-codex-2", "ACCT-WORK", ""),
            ]),
        ])

        let scan = piScanner(files: files).scan()

        XCTAssertEqual(scan.logins.map(\.providerID), ["openai-codex"])
    }

    func testPiCodexProviderIDShape() {
        XCTAssertTrue(PiCodexLoginScanner.isCodexProvider("openai-codex"))
        XCTAssertTrue(PiCodexLoginScanner.isCodexProvider("openai-codex-2"))
        XCTAssertTrue(PiCodexLoginScanner.isCodexProvider("openai-codex-12"))
        XCTAssertFalse(PiCodexLoginScanner.isCodexProvider("openai-codex-"))
        XCTAssertFalse(PiCodexLoginScanner.isCodexProvider("openai-codex-work"))
        XCTAssertNil(PiProviderMapping.cardID(forPiProvider: "openai-codex-3"))
    }

    func testDefaultObserverUsesConfiguredCommaPathAsSingleHomeAndAccessTokenIdentity() {
        let files = FakeFiles([
            "/missing, /second/auth.json": Fixtures.codexAuth(accountID: nil, email: "me@test", accessAccountID: "ACCT"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CODEX_HOME": "/missing, /second"]),
            files: files, keychain: FakeKeychain(), homeDirectory: { [home] in home }
        )

        XCTAssertEqual(observer.observeCodex(),
                       .resolved(identityKey: "acct", label: "me@test", anchor: "/missing, /second"))
    }

    func testDefaultObserverLeavesEmailOnlyLoginUnresolved() {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: nil, email: "a@test"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(), homeDirectory: { [home] in home }
        )

        XCTAssertEqual(observer.observeCodex(), .unresolved(reason: "credentials present but no account identity"))
    }

    // MARK: - Scoped auth store

    func testDiscoveredHomeCredentialsAreReadOnly() throws {
        let credential = Fixtures.codexAuth(accountID: "A", email: "a@test")
        let files = FakeFiles(["/Users/dev/.codex-work/auth.json": credential])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/Users/dev/.codex"]),
            files: files, keychain: FakeKeychain(),
            expectedIdentity: try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test")),
            additionalAuthHomes: ["/Users/dev/.codex-work"]
        )

        let candidate = try XCTUnwrap(store.loadAuthCandidates().first)

        XCTAssertTrue(candidate.readOnly)
        XCTAssertNil(candidate.auth.tokens?.refreshToken)
        XCTAssertThrowsError(try store.save(candidate))
        XCTAssertEqual(files.files["/Users/dev/.codex-work/auth.json"], credential)
    }

    func testChangedHomeLoginIsRejectedBeforeUse() throws {
        let files = FakeFiles([
            "/home/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test"),
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/home"]),
            files: files, keychain: FakeKeychain(),
            expectedIdentity: try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test")),
            additionalAuthHomes: ["/home"]
        )

        XCTAssertNotNil(store.loadAuthCandidates().first)
        files.files["/home/auth.json"] = Fixtures.codexAuth(accountID: "B", email: "b@test")
        XCTAssertTrue(store.loadAuthCandidates().isEmpty)
    }

    func testPiCredentialsReloadAndFallBackAcrossMatchingProviderIDs() throws {
        let expired = Fixtures.token(accountID: "ACCT", email: "me@test")
        let current = Fixtures.token(accountID: "ACCT", email: "me@test", exp: Date(timeIntervalSince1970: 2_000_000_000))
        let files = FakeFiles([
            "/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(expired)","accountId":"ACCT"},"openai-codex-2":{"type":"oauth","access":"\#(current)","accountId":"ACCT"}}"#,
        ])
        let store = CodexAuthStore(
            files: files, keychain: FakeKeychain(),
            expectedIdentity: try XCTUnwrap(CodexAccountIdentity(accountID: "ACCT", email: "me@test")),
            piCredentialSources: [
                CodexPiCredentialSource(path: "/pi/auth.json", providerID: "openai-codex"),
                CodexPiCredentialSource(path: "/pi/auth.json", providerID: "openai-codex-2"),
            ]
        )

        let candidates = store.loadAuthCandidates()
        XCTAssertEqual(candidates.map { $0.auth.tokens?.accessToken }, [expired, current])
        XCTAssertTrue(candidates.allSatisfy(\.readOnly))
        XCTAssertThrowsError(try store.save(candidates[0]))

        let renewed = Fixtures.token(accountID: "ACCT", email: "me@test", exp: Date(timeIntervalSince1970: 2_100_000_000))
        files.files["/pi/auth.json"] = #"{"openai-codex":{"type":"oauth","access":"\#(renewed)","accountId":"ACCT"}}"#

        XCTAssertEqual(store.loadAuthCandidates().map { $0.auth.tokens?.accessToken }, [renewed])
    }

    func testProviderFallsBackAcrossMatchingPiCredentials() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Fixtures.token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let second = Fixtures.token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(7200))
        let files = FakeFiles([
            "/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(first)","accountId":"A"},"openai-codex-2":{"type":"oauth","access":"\#(second)","accountId":"A"}}"#,
        ])
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer \(first)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Fixtures.usageResponse()
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                files: files, keychain: FakeKeychain(), now: { now },
                expectedIdentity: try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test")),
                piCredentialSources: [
                    .init(path: "/pi/auth.json", providerID: "openai-codex"),
                    .init(path: "/pi/auth.json", providerID: "openai-codex-2"),
                ]
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.prefix(2).map { $0.headers["Authorization"] },
                       ["Bearer \(first)", "Bearer \(second)"])
    }
}
