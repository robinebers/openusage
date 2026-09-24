import XCTest
@testable import OpenUsage

@MainActor
final class CodexPR1266ReviewTests: XCTestCase {
    private func b64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func token(accountID: String? = nil, email: String, exp: Date? = nil) -> String {
        var claims = [#""https://api.openai.com/profile":{"email":"\#(email)"}"#]
        if let accountID {
            claims.append(#""https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"}"#)
        }
        if let exp { claims.append(#""exp":\#(Int(exp.timeIntervalSince1970))"#) }
        return "\(b64url(#"{"alg":"RS256"}"#)).\(b64url("{\(claims.joined(separator: ","))}")).sig"
    }

    private func authJSON(
        accountID: String?,
        email: String,
        accessToken: String? = nil,
        refreshToken: String? = "rt"
    ) -> String {
        let token = accessToken ?? token(accountID: accountID, email: email)
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: token,
                refreshToken: refreshToken,
                idToken: self.token(accountID: accountID, email: email),
                accountID: accountID
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        return String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self)
    }

    private func defaults() -> UserDefaults {
        let name = "OpenUsageTests.CodexPR1266Review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSiblingDiscoveryIncludesHiddenCodexDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex-work"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent(".codex-file"))

        let names = CodexAccountDiscovery.listSubdirectories(root.path)

        XCTAssertTrue(names.contains(".codex-work"))
        XCTAssertFalse(names.contains(".codex-file"))
    }

    func testSwapMainAndSavedHomesStayReadOnlyThroughRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let credential = authJSON(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":{"accountId":"A","email":"a@test"}}]}"#,
            "/test/main/auth.json": credential,
            "/test/saved/auth.json": credential,
        ])
        let environment = FakeEnvironment(["CODEX_HOME": "/test/main", "XSWAP_HOME": "/test/swap"])
        let observer = DefaultAccountObserver(
            environment: environment,
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/test") }
        )
        let discovery = CodexAccountDiscovery(
            environment: environment,
            files: files,
            homeDirectory: { URL(fileURLWithPath: "/test") },
            listDirectories: { _ in [] }
        )
        let assembly = await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults()),
            families: ["codex"],
            codexDiscovery: discovery
        )
        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(card.authHomes, ["/test/main", "/test/saved"])
        XCTAssertTrue(card.writableAuthHomes.isEmpty)

        let http = RoutingHTTPClient { _ in
            XCTFail("Read-only expired Swap credentials must not make requests")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: environment,
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentity: card.identity,
                additionalAuthHomes: card.authHomes,
                writableAuthHomes: Set(card.writableAuthHomes)
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["/test/main/auth.json"], credential)
        XCTAssertEqual(files.files["/test/saved/auth.json"], credential)
    }

    func testRejectedHomeRefreshFallsBackToMatchingPiCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let valid = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let original = authJSON(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/home/auth.json": original,
            "/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(valid)","accountId":"A"}}"#,
        ])
        let http = RoutingHTTPClient { request in
            if request.url.host == "auth.openai.com" {
                return HTTPResponse(
                    statusCode: 400,
                    headers: [:],
                    body: Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8)
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
                writableAuthHomes: ["/home"],
                piCredentialSources: [.init(path: "/pi/auth.json", providerID: "openai-codex")]
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests[0].url.host, "auth.openai.com")
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer \(valid)")
        XCTAssertEqual(files.files["/home/auth.json"], original)
    }

    func testDefaultObserverLeavesEmailOnlyLoginUnresolved() {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": authJSON(accountID: nil, email: "a@test"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "credentials present but no account identity")
        )
    }

    func testSwapHomesStayReadOnlyWhenRegistryIdentityOmitsEmail() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(-60))
        let credential = authJSON(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":{"accountId":"A"}}]}"#,
            "/test/main/auth.json": credential,
            "/test/saved/auth.json": credential,
        ])
        let environment = FakeEnvironment(["CODEX_HOME": "/test/main", "XSWAP_HOME": "/test/swap"])
        let observer = DefaultAccountObserver(
            environment: environment,
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/test") }
        )
        let assembly = await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults()),
            families: ["codex"],
            codexDiscovery: CodexAccountDiscovery(
                environment: environment,
                files: files,
                homeDirectory: { URL(fileURLWithPath: "/test") },
                listDirectories: { _ in [] }
            )
        )
        XCTAssertFalse(assembly.codexCards.isEmpty)

        let http = RoutingHTTPClient { _ in
            XCTFail("Swap-managed credentials must not rotate")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        for card in assembly.codexCards {
            XCTAssertTrue(card.writableAuthHomes.isEmpty)
            let provider = CodexProvider(
                authStore: CodexAuthStore(
                    environment: environment,
                    files: files,
                    keychain: FakeKeychain(),
                    now: { now },
                    expectedIdentity: card.identity,
                    additionalAuthHomes: card.authHomes,
                    writableAuthHomes: Set(card.writableAuthHomes)
                ),
                usageClient: CodexUsageClient(http: http),
                now: { now }
            )
            _ = await provider.refresh()
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["/test/main/auth.json"], credential)
        XCTAssertEqual(files.files["/test/saved/auth.json"], credential)
    }

    func testIncompleteDefaultLoginBlocksUnattributedHistoryForSiblingAccount() async throws {
        try await assertIncompleteDefaultLoginBlocksUnattributedHistory(siblingAccountID: "B", siblingKey: "b|b@test")
    }

    func testIncompleteDefaultLoginBlocksUnattributedHistoryForSameWorkspaceSibling() async throws {
        try await assertIncompleteDefaultLoginBlocksUnattributedHistory(siblingAccountID: "A", siblingKey: "a|b@test")
    }

    private func assertIncompleteDefaultLoginBlocksUnattributedHistory(
        siblingAccountID: String,
        siblingKey: String
    ) async throws {
        let accountOnly = "\(b64url(#"{"alg":"RS256"}"#)).\(b64url(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"A"}}"#)).sig"
        let defaultAuth = CodexAuth(
            tokens: CodexTokens(accessToken: accountOnly, refreshToken: "rt", idToken: accountOnly, accountID: "A"),
            lastRefresh: nil,
            apiKey: nil
        )
        let files = FakeFiles([
            "/test/.codex/auth.json": String(decoding: try JSONEncoder().encode(defaultAuth), as: UTF8.self),
            "/test/.codex-b/auth.json": authJSON(accountID: siblingAccountID, email: "b@test"),
        ])
        let environment = FakeEnvironment([:])
        let assembly = await ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(
                environment: environment,
                files: files,
                keychain: FakeKeychain(),
                homeDirectory: { URL(fileURLWithPath: "/test") }
            ),
            accountsStore: ProviderAccountsStore(defaults: defaults()),
            families: ["codex"],
            codexDiscovery: CodexAccountDiscovery(
                environment: environment,
                files: files,
                homeDirectory: { URL(fileURLWithPath: "/test") },
                listDirectories: { $0 == "/test" ? [".codex-b"] : [] }
            )
        )

        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(assembly.codexCards.count, 1)
        XCTAssertEqual(card.identity.key, siblingKey)
        XCTAssertFalse(card.allowsUnattributedHistory)
    }

    func testRejectedUnexpiredHomeTokenRenewsAndRetries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rejected = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(3600))
        let renewed = token(accountID: "A", email: "a@test", exp: now.addingTimeInterval(7200))
        let files = FakeFiles([
            "/home/auth.json": authJSON(accountID: "A", email: "a@test", accessToken: rejected),
        ])
        let http = RoutingHTTPClient { request in
            if request.url.host == "auth.openai.com" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"\#(renewed)","refresh_token":"rt2"}"#.utf8)
                )
            }
            if request.headers["Authorization"] == "Bearer \(rejected)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/home"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentity: try XCTUnwrap(CodexAccountIdentity(accountID: "A", email: "a@test")),
                writableAuthHomes: ["/home"]
            ),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests[1].url.host, "auth.openai.com")
        XCTAssertEqual(http.requests[2].headers["Authorization"], "Bearer \(renewed)")
        XCTAssertTrue(files.files["/home/auth.json"]?.contains(renewed) == true)
    }
}
