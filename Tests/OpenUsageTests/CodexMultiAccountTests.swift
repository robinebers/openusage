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

    private func token(accountID: String?, email: String?, exp: Date? = nil) -> String {
        var claims: [String] = []
        if let accountID {
            claims.append(#""https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)","chatgpt_plan_type":"pro"}"#)
        }
        if let email {
            claims.append(#""https://api.openai.com/profile":{"email":"\#(email)"}"#)
        }
        if let exp { claims.append(#""exp":\#(Int(exp.timeIntervalSince1970))"#) }
        return "\(b64url(#"{"alg":"RS256"}"#)).\(b64url("{\(claims.joined(separator: ","))}")).sig"
    }

    private func codexAuth(
        accountID: String?,
        email: String,
        accessAccountID: String? = nil,
        refreshToken: String? = "rt"
    ) -> String {
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: token(accountID: accessAccountID ?? accountID, email: email),
                refreshToken: refreshToken,
                idToken: token(accountID: accountID, email: email),
                accountID: accountID
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        return String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self)
    }

    private func piAuth(_ entries: [(provider: String, accountID: String, email: String)]) -> String {
        let body = entries.map { entry in
            #""\#(entry.provider)":{"type":"oauth","access":"\#(token(accountID: entry.accountID, email: entry.email))","refresh":"rt","accountId":"\#(entry.accountID)"}"#
        }.joined(separator: ",")
        return "{\(body)}"
    }

    private func makeDiscovery(
        environment: [String: String] = [:],
        files: FakeFiles,
        directories: [String: [String]] = [:]
    ) -> CodexAccountDiscovery {
        CodexAccountDiscovery(
            environment: FakeEnvironment(environment),
            files: files,
            homeDirectory: { [home] in home },
            listDirectories: { directories[$0] ?? [] }
        )
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexMultiAccount.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func assemble(
        files: FakeFiles,
        directories: [String: [String]] = [:],
        environment: [String: String] = [:],
        defaults: UserDefaults? = nil
    ) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { [home] in home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults ?? makeScratchDefaults()),
            families: ["codex"],
            codexDiscovery: makeDiscovery(environment: environment, files: files, directories: directories)
        )
    }

    func testCandidateHomesCoverConfiguredDefaultsAndSiblingDirectories() {
        let discovery = makeDiscovery(
            environment: ["CODEX_HOME": "~/.codex, /opt/codex-ci"],
            files: FakeFiles(),
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

    func testIdentityFallsBackFromIncompleteIDTokenToAccessToken() throws {
        let auth = try XCTUnwrap(CodexAuthStore.parseAuth(codexAuth(
            accountID: nil,
            email: "ME@WORK.TEST",
            accessAccountID: "ACCT-WORK"
        )))

        XCTAssertEqual(CodexAccountIdentity(auth: auth)?.key, "acct-work|me@work.test")
    }

    func testPiDiscoveryKeepsEveryMatchingIdentityWithoutSnapshottingTokens() {
        let files = FakeFiles([
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex-2", "ACCT-WORK", "me@work.test"),
                ("openai-codex", "ACCT-HOME", "me@home.test"),
            ]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ])

        let logins = makeDiscovery(files: files).piLogins()

        XCTAssertEqual(logins.map(\.providerID), ["openai-codex", "openai-codex-2"])
        XCTAssertEqual(logins.map(\.identity.key), ["acct-home|me@home.test", "acct-work|me@work.test"])
        XCTAssertEqual(logins.map(\.label), [nil, "work"])
        XCTAssertEqual(Set(logins.map(\.authPath)), ["/Users/dev/.pi/agent/auth.json"])
    }

    func testHomesAndPiMergeByWorkspaceAndUserIdentity() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-work/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.codex-personal/auth.json": codexAuth(accountID: "ACCT-HOME", email: "me@home.test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex", "ACCT-HOME", "me@home.test"),
                ("openai-codex-2", "ACCT-WORK", "me@work.test"),
            ]),
            "/Users/dev/.pi/agent/multi-pass.json": #"{"subscriptions":[{"provider":"openai-codex","index":2,"label":"work"}]}"#,
        ])

        let assembly = await assemble(
            files: files,
            directories: ["/Users/dev": [".codex-work", ".codex-personal"]]
        )

        XCTAssertEqual(assembly.codexCards.count, 2)
        let work = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-work|me@work.test" })
        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-home|me@home.test" })
        XCTAssertEqual(work.id, "codex")
        XCTAssertEqual(personal.id, ProviderAccountID.make(
            family: "codex", identityKey: "acct-home|me@home.test"
        ))
        XCTAssertEqual(work.displayName, "Codex: work")
        XCTAssertEqual(work.authHomes, ["/Users/dev/.codex", "/Users/dev/.codex-work"])
        XCTAssertEqual(personal.authHomes, ["/Users/dev/.codex-personal"])
        XCTAssertEqual(work.piCredentialSources.map(\.providerID), ["openai-codex-2"])
        XCTAssertEqual(personal.piCredentialSources.map(\.providerID), ["openai-codex"])
        XCTAssertFalse(work.allowsUnattributedHistory)
        XCTAssertFalse(personal.allowsUnattributedHistory)
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-work|me@work.test")
        XCTAssertEqual(assembly.identityKeysByCard[personal.id], "acct-home|me@home.test")
    }

    func testUsersInTheSameWorkspaceRemainSeparateCards() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT", email: "a@example.test"),
            "/Users/dev/.codex-b/auth.json": codexAuth(accountID: "ACCT", email: "b@example.test"),
        ])

        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-b"]])

        XCTAssertEqual(assembly.codexCards.map(\.identity.key), [
            "acct|a@example.test", "acct|b@example.test",
        ])
    }

    func testRegistryOrderAndBareCardOwnershipSurviveDefaultSwitch() async throws {
        let defaults = makeScratchDefaults()
        let work = codexAuth(accountID: "ACCT-WORK", email: "me@work.test")
        let personal = codexAuth(accountID: "ACCT-HOME", email: "me@home.test")
        let directories = ["/Users/dev": [".codex-personal"]]

        let first = await assemble(
            files: FakeFiles([
                "/Users/dev/.codex/auth.json": work,
                "/Users/dev/.codex-personal/auth.json": personal,
            ]),
            directories: directories,
            defaults: defaults
        )
        let personalID = try XCTUnwrap(first.codexCards.first {
            $0.identity.key == "acct-home|me@home.test"
        }?.id)

        let swapped = await assemble(
            files: FakeFiles([
                "/Users/dev/.codex/auth.json": personal,
                "/Users/dev/.codex-personal/auth.json": work,
            ]),
            directories: directories,
            defaults: defaults
        )

        XCTAssertEqual(swapped.codexCards.map(\.id), ["codex", personalID])
        XCTAssertEqual(swapped.identityKeysByCard["codex"], "acct-work|me@work.test")
        XCTAssertEqual(swapped.identityKeysByCard[personalID], "acct-home|me@home.test")
    }

    func testPiOnlyAccountGetsAReadOnlyCredentialSource() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex-2", "ACCT-HOME", "me@home.test"),
            ]),
        ])

        let assembly = await assemble(files: files)
        let personal = try XCTUnwrap(assembly.codexCards.first {
            $0.identity.key == "acct-home|me@home.test"
        })
        XCTAssertTrue(personal.authHomes.isEmpty)
        XCTAssertEqual(personal.piCredentialSources.map(\.providerID), ["openai-codex-2"])

        let store = CodexAuthStore(
            files: files,
            keychain: FakeKeychain(),
            expectedIdentity: personal.identity,
            additionalAuthHomes: personal.authHomes,
            piCredentialSources: personal.piCredentialSources
        )
        let candidate = try XCTUnwrap(store.loadAuthCandidates().first)
        XCTAssertTrue(candidate.readOnly)
        XCTAssertNil(candidate.auth.tokens?.refreshToken)
        XCTAssertEqual(candidate.auth.tokens?.accountID, "acct-home")
    }

    func testPiCredentialsReloadAndFallBackAcrossMatchingProviderIDs() throws {
        let expired = token(accountID: "ACCT", email: "me@test")
        let current = token(accountID: "ACCT", email: "me@test", exp: Date(timeIntervalSince1970: 2_000_000_000))
        let files = FakeFiles([
            "/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(expired)","accountId":"ACCT"},"openai-codex-2":{"type":"oauth","access":"\#(current)","accountId":"ACCT"}}"#,
        ])
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "ACCT", email: "me@test"))
        let sources = [
            CodexPiCredentialSource(path: "/pi/auth.json", providerID: "openai-codex"),
            CodexPiCredentialSource(path: "/pi/auth.json", providerID: "openai-codex-2"),
        ]
        let store = CodexAuthStore(
            files: files,
            keychain: FakeKeychain(),
            expectedIdentity: identity,
            piCredentialSources: sources
        )

        XCTAssertEqual(store.loadAuthCandidates().map { $0.auth.tokens?.accessToken }, [expired, current])

        let renewed = token(accountID: "ACCT", email: "me@test", exp: Date(timeIntervalSince1970: 2_100_000_000))
        files.files["/pi/auth.json"] = #"{"openai-codex":{"type":"oauth","access":"\#(renewed)","accountId":"ACCT"}}"#

        XCTAssertEqual(store.loadAuthCandidates().map { $0.auth.tokens?.accessToken }, [renewed])
    }

    func testProviderFallsBackAcrossMatchingPiCredentials() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let second = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(7200))
        let files = FakeFiles([
            "/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(first)","accountId":"A"},"openai-codex-2":{"type":"oauth","access":"\#(second)","accountId":"A"}}"#,
        ])
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer \(first)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test"))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentity: identity,
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
        XCTAssertEqual(http.requests.prefix(2).map { $0.headers["Authorization"] }, [
            "Bearer \(first)", "Bearer \(second)",
        ])
    }

    func testChangedHomeLoginIsRejectedBeforeUse() throws {
        let files = FakeFiles([
            "/home/auth.json": codexAuth(accountID: "A", email: "a@test"),
        ])
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test"))
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/home"]),
            files: files,
            keychain: FakeKeychain(),
            expectedIdentity: identity,
            additionalAuthHomes: ["/home"]
        )

        XCTAssertNotNil(store.loadAuthCandidates().first)
        files.files["/home/auth.json"] = codexAuth(accountID: "B", email: "b@test")
        XCTAssertTrue(store.loadAuthCandidates().isEmpty)
    }

    func testRegularHomesRemainWritableWhileSwapAndPiSourcesAreReadOnly() throws {
        let credential = codexAuth(accountID: "A", email: "a@test")
        let files = FakeFiles([
            "/home/auth.json": credential,
            "/swap/auth.json": credential,
            "/pi/auth.json": piAuth([("openai-codex", "A", "a@test")]),
        ])
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test"))
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/home"]),
            files: files,
            keychain: FakeKeychain(),
            expectedIdentity: identity,
            additionalAuthHomes: ["/swap"],
            writableAuthHomes: ["/home"],
            piCredentialSources: [.init(path: "/pi/auth.json", providerID: "openai-codex")]
        )

        let candidates = store.loadAuthCandidates()
        XCTAssertEqual(candidates.count, 3)
        XCTAssertFalse(candidates[0].readOnly)
        XCTAssertNotNil(candidates[0].auth.tokens?.refreshToken)
        XCTAssertTrue(candidates[1].readOnly)
        XCTAssertNil(candidates[1].auth.tokens?.refreshToken)
        XCTAssertTrue(candidates[2].readOnly)
        XCTAssertNil(candidates[2].auth.tokens?.refreshToken)
    }

    func testRegularHomeRefreshPersistsMatchingRotatedCredentials() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldToken = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let newToken = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: oldToken, refreshToken: "rt", idToken: oldToken, accountID: "A"),
            lastRefresh: nil,
            apiKey: nil
        )
        let files = FakeFiles([
            "/home/auth.json": String(decoding: try JSONEncoder().encode(auth), as: UTF8.self),
        ])
        let http = RoutingHTTPClient { request in
            if request.url.host == "auth.openai.com" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"\#(newToken)","id_token":"\#(newToken)"}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test"))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/home"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentity: identity,
                additionalAuthHomes: ["/home"],
                writableAuthHomes: ["/home"]
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/home/auth.json"]))?.tokens?.accessToken, newToken)
        XCTAssertTrue(http.requests.contains { $0.headers["ChatGPT-Account-Id"] == "a" })
    }

    func testLoginChangedDuringRefreshIsNeverOverwritten() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldToken = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let newToken = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: oldToken, refreshToken: "rt", idToken: oldToken, accountID: "A"),
            lastRefresh: nil,
            apiKey: nil
        )
        let replacement = codexAuth(accountID: "B", email: "b@test")
        let files = FakeFiles([
            "/home/auth.json": String(decoding: try JSONEncoder().encode(auth), as: UTF8.self),
        ])
        let http = RoutingHTTPClient { request in
            if request.url.host == "auth.openai.com" {
                files.files["/home/auth.json"] = replacement
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"\#(newToken)","id_token":"\#(newToken)"}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test"))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/home"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentity: identity,
                additionalAuthHomes: ["/home"],
                writableAuthHomes: ["/home"]
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(files.files["/home/auth.json"], replacement)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testCatalogKeepsMultiAccountLocalHistoryUnattributedAndPiReadOnly() async {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "A", email: "a@test"),
            "/Users/dev/.codex-b/auth.json": codexAuth(accountID: "B", email: "b@test"),
            "/Users/dev/.pi/agent/auth.json": piAuth([
                ("openai-codex", "A", "a@test"),
                ("openai-codex-2", "B", "b@test"),
            ]),
        ])
        let assembly = await assemble(files: files, directories: ["/Users/dev": [".codex-b"]])
        let providers = ProviderCatalog.make(
            defaults: makeScratchDefaults(),
            codexCards: assembly.codexCards
        ).compactMap { $0 as? CodexProvider }

        XCTAssertEqual(providers.count, 2)
        XCTAssertTrue(providers.allSatisfy { !$0.allowsUnattributedHistory })
        XCTAssertEqual(providers.map { $0.authStore.piCredentialSources.count }, [1, 1])
    }

    func testDefaultObserverUsesConfiguredHomeListAndAccessTokenIdentity() {
        let files = FakeFiles([
            "/second/auth.json": codexAuth(
                accountID: nil,
                email: "me@test",
                accessAccountID: "ACCT"
            ),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CODEX_HOME": "/missing, /second"]),
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "acct", label: "me@test", anchor: "/second")
        )
    }

    func testPiCodexProviderIDShape() {
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex"))
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex-2"))
        XCTAssertTrue(CodexAccountDiscovery.isPiCodexProvider("openai-codex-12"))
        XCTAssertFalse(CodexAccountDiscovery.isPiCodexProvider("openai-codex-"))
        XCTAssertFalse(CodexAccountDiscovery.isPiCodexProvider("openai-codex-work"))
        XCTAssertNil(PiProviderMapping.cardID(forPiProvider: "openai-codex-3"))
    }
}
