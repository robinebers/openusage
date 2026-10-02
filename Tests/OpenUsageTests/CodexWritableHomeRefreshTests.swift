import XCTest
@testable import OpenUsage

/// Token refresh on account cards: only an independent Codex home may rotate and persist its token.
@MainActor
final class CodexWritableHomeRefreshTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var identity: CodexAccountIdentity { CodexAccountIdentity(accountID: "A", email: "a@test")! }
    private var expired: String { Fixtures.token(accountID: "A", email: "a@test", exp: Self.now.addingTimeInterval(-60)) }
    private var valid: String { Fixtures.token(accountID: "A", email: "a@test", exp: Self.now.addingTimeInterval(3600)) }

    private func store(
        files: any TextFileAccessing, keychain: FakeKeychain = FakeKeychain(), environment: [String: String],
        additional: [String] = [], writable: [String] = [], pi: [CodexPiCredentialSource] = []
    ) -> CodexAuthStore {
        CodexAuthStore(
            environment: FakeEnvironment(environment), files: files, keychain: keychain, now: { Self.now },
            expectedIdentity: identity, additionalAuthHomes: additional,
            writableAuthHomes: Set(writable.map { CodexHomeScanner.canonicalHome($0) }), piCredentialSources: pi
        )
    }

    private func provider(_ store: CodexAuthStore, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(authStore: store, usageClient: CodexUsageClient(http: http), now: { Self.now })
    }

    private nonisolated static func refreshResponse(_ token: String, refreshToken: String? = nil, idToken: String? = nil) -> HTTPResponse {
        var body = #""access_token":"\#(token)""#
        if let refreshToken { body += #","refresh_token":"\#(refreshToken)""# }
        if let idToken { body += #","id_token":"\#(idToken)""# }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(body)}".utf8))
    }

    func testIndependentHomeIsWritableWhileSwapPiAndKeychainStayReadOnly() throws {
        let credential = Fixtures.codexAuth(accountID: "A", email: "a@test")
        let files = FakeFiles([
            "/test/home/auth.json": credential,
            "/test/swap-main/auth.json": credential,
            "/test/pi/auth.json": Fixtures.piAuth([("openai-codex", "A", "a@test")]),
        ])
        let store = store(
            files: files, keychain: FakeKeychain(credential), environment: ["CODEX_HOME": "/test/home"],
            additional: ["/test/swap-main"], writable: ["/test/home"],
            pi: [.init(path: "/test/pi/auth.json", providerID: "openai-codex")]
        )

        let candidates = store.loadAuthCandidates() + [try XCTUnwrap(store.loadKeychainAuth())]

        XCTAssertEqual(candidates.count, 4)
        XCTAssertFalse(candidates[0].readOnly)
        XCTAssertEqual(candidates[0].auth.tokens?.refreshToken, "rt")
        for readOnly in candidates.dropFirst() {
            XCTAssertTrue(readOnly.readOnly, "\(readOnly.source)")
            XCTAssertNil(readOnly.auth.tokens?.refreshToken, "\(readOnly.source)")
        }
    }

    func testAliasOfAWritableHomeResolvesToTheSameHome() throws {
        let root = try makeScratchDirectory(["home"], links: ["alias": "home"])
        let files = FakeFiles(["\(root)/alias/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test")])
        let store = store(files: files, environment: ["CODEX_HOME": "\(root)/alias"], writable: ["\(root)/home"])

        XCTAssertEqual(try XCTUnwrap(store.loadAuthCandidates().first).readOnly, false)
    }

    func testIndependentHomeRefreshPersistsRotatedCredentials() async throws {
        let files = FakeFiles([
            "/test/home/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired),
        ])
        let http = RoutingHTTPClient { [valid] request in
            request.url.host == "auth.openai.com"
                ? Self.refreshResponse(valid, refreshToken: "rt2", idToken: valid) : Fixtures.usageResponse()
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/test/home/auth.json"])))
        XCTAssertEqual(saved.tokens?.accessToken, valid)
        XCTAssertEqual(saved.tokens?.refreshToken, "rt2")
        XCTAssertTrue(http.requests.contains { $0.headers["ChatGPT-Account-Id"] == "a" })
    }

    func testUnpersistedRotationStillServesTheRefresh() async throws {
        let auth = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = UnwritableFiles(FakeFiles(["/test/home/auth.json": auth]))
        let http = RoutingHTTPClient { [valid] request in
            if request.url.host == "auth.openai.com" { return Self.refreshResponse(valid, refreshToken: "rt2") }
            guard request.headers["Authorization"] == "Bearer \(valid)" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Fixtures.usageResponse()
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.filter { $0.url.host == "auth.openai.com" }.count, 1)
        XCTAssertEqual(files.files.files["/test/home/auth.json"], auth)
    }

    func testUnpersistedRotationRetriesWithTheRotatedRefreshToken() async throws {
        let renewed = Fixtures.token(accountID: "A", email: "a@test", exp: Self.now.addingTimeInterval(7200))
        let auth = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = UnwritableFiles(FakeFiles(["/test/home/auth.json": auth]))
        let http = RoutingHTTPClient { [valid] request in
            if request.url.host == "auth.openai.com" {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                return body.hasSuffix("refresh_token=rt2")
                    ? Self.refreshResponse(renewed, refreshToken: "rt3")
                    : Self.refreshResponse(valid, refreshToken: "rt2")
            }
            if request.headers["Authorization"] == "Bearer \(valid)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Fixtures.usageResponse()
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        let refreshBodies = http.requests.filter { $0.url.host == "auth.openai.com" }
            .map { String(decoding: $0.body ?? Data(), as: UTF8.self).components(separatedBy: "refresh_token=").last }
        XCTAssertEqual(refreshBodies, ["rt", "rt2"])
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer \(renewed)")
        XCTAssertEqual(files.files.files["/test/home/auth.json"], auth)
    }

    func testLoginChangedDuringRefreshIsNeverOverwritten() async throws {
        let replacement = Fixtures.codexAuth(accountID: "B", email: "b@test")
        let files = FakeFiles([
            "/test/home/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired),
        ])
        let http = RoutingHTTPClient { [valid] request in
            guard request.url.host == "auth.openai.com" else {
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            files.files["/test/home/auth.json"] = replacement
            return Self.refreshResponse(valid, idToken: valid)
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(files.files["/test/home/auth.json"], replacement)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testSaveRefusesToOverwriteALoginThatChangedSinceItWasRead() throws {
        let original = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let replacement = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: valid, refreshToken: "codex-rt")
        let files = FakeFiles(["/test/home/auth.json": original])
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])
        let loaded = try XCTUnwrap(store.loadAuth(at: "/test/home/auth.json"))
        var rotated = loaded
        rotated.auth.tokens?.refreshToken = "rt2"

        files.files["/test/home/auth.json"] = replacement
        XCTAssertThrowsError(try store.save(rotated, replacing: loaded)) { error in
            XCTAssertEqual(error as? CodexAuthError, .tokenConflict)
        }
        XCTAssertEqual(files.files["/test/home/auth.json"], replacement)

        files.files["/test/home/auth.json"] = original
        try store.save(rotated, replacing: loaded)
        XCTAssertEqual(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/test/home/auth.json"]))?.tokens?.refreshToken, "rt2")
    }

    func testRejectedHomeRefreshFallsBackToMatchingPiCredential() async throws {
        let original = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "/test/home/auth.json": original,
            "/test/pi/auth.json": #"{"openai-codex":{"type":"oauth","access":"\#(valid)","accountId":"A"}}"#,
        ])
        let http = RoutingHTTPClient { request in
            request.url.host == "auth.openai.com"
                ? HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8))
                : Fixtures.usageResponse()
        }
        let store = store(
            files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"],
            pi: [.init(path: "/test/pi/auth.json", providerID: "openai-codex")]
        )

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests[0].url.host, "auth.openai.com")
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer \(valid)")
        XCTAssertEqual(files.files["/test/home/auth.json"], original)
    }

    func testRejectedUnexpiredHomeTokenRenewsAndRetries() async throws {
        let renewed = Fixtures.token(accountID: "A", email: "a@test", exp: Self.now.addingTimeInterval(7200))
        let files = FakeFiles([
            "/test/home/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: valid),
        ])
        let http = RoutingHTTPClient { [valid] request in
            if request.url.host == "auth.openai.com" { return Self.refreshResponse(renewed, refreshToken: "rt2") }
            if request.headers["Authorization"] == "Bearer \(valid)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Fixtures.usageResponse()
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests[1].url.host, "auth.openai.com")
        XCTAssertEqual(http.requests[2].headers["Authorization"], "Bearer \(renewed)")
        XCTAssertEqual(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/test/home/auth.json"]))?.tokens?.accessToken, renewed)
    }

    func testRotationPersistsBeforeRejectingAnIdentityWithoutEmail() async throws {
        let rotated = Fixtures.token(accountID: "A", email: nil, exp: Self.now.addingTimeInterval(3600))
        let files = FakeFiles([
            "/test/home/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired),
        ])
        let http = RoutingHTTPClient { request in
            request.url.host == "auth.openai.com"
                ? Self.refreshResponse(rotated, refreshToken: "rt2", idToken: rotated)
                : HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let store = store(files: files, environment: ["CODEX_HOME": "/test/home"], writable: ["/test/home"])

        let snapshot = await provider(store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/test/home/auth.json"])))
        XCTAssertEqual(saved.tokens?.refreshToken, "rt2")
        XCTAssertEqual(http.requests.count, 1)
    }

    // MARK: - Assembly

    func testSymlinkedCodexHomeAliasOfSwapMainHomeStaysReadOnly() async throws {
        let root = try makeScratchDirectory(["main", ".codex-work"], links: ["alias": "main"])
        let swapCredential = Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired)
        let files = FakeFiles([
            "\(root)/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"\#(root)/main","accounts":[{"number":1,"alias":"A","home":"\#(root)/saved","identity":{"accountId":"A","email":"a@test"}}]}"#,
            "\(root)/alias/auth.json": swapCredential,
            "\(root)/saved/auth.json": swapCredential,
            "\(root)/.codex-work/auth.json": Fixtures.codexAuth(accountID: "B", email: "b@test"),
        ])
        let environment = ["CODEX_HOME": "\(root)/alias", "XSWAP_HOME": "\(root)/swap"]
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment), files: files, keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: root) }
        )

        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"], listCodexHomeDirectories: { $0 == root ? [".codex-work"] : [] }
        )

        let swapCard = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "a" })
        let homeCard = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "b" })
        XCTAssertEqual(swapCard.writableAuthHomes, [])
        XCTAssertEqual(homeCard.writableAuthHomes, [CodexHomeScanner.canonicalHome("\(root)/.codex-work")])

        let http = RoutingHTTPClient { _ in
            XCTFail("Swap-managed credentials must not rotate")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let store = CodexAuthStore(
            environment: FakeEnvironment(environment), files: files, keychain: FakeKeychain(), now: { Self.now },
            expectedIdentity: swapCard.identity, additionalAuthHomes: swapCard.authHomes,
            writableAuthHomes: Set(swapCard.writableAuthHomes), piCredentialSources: swapCard.piCredentialSources
        )
        let snapshot = await provider(store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["\(root)/alias/auth.json"], swapCredential)
    }

    func testSwapSlotWithoutIdentityStaysReadOnlyEvenAsCodexHome() async throws {
        let credential = Fixtures.codexAuth(accountID: "B", email: "b@test", accessToken: Fixtures.token(accountID: "B", email: "b@test", exp: Self.now.addingTimeInterval(-60)))
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":{"accountId":"A","email":"a@test"}},{"number":2,"alias":"B","home":"/test/slot-b","identity":null}]}"#,
            "/test/main/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test"),
            "/test/slot-b/auth.json": credential,
        ])
        let environment = ["CODEX_HOME": "/test/slot-b", "XSWAP_HOME": "/test/swap"]
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment), files: files, keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/test") }
        )

        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"], listCodexHomeDirectories: { _ in [] }
        )

        let cardB = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "b" })
        XCTAssertEqual(cardB.authHomes, ["/test/slot-b"])
        XCTAssertEqual(cardB.writableAuthHomes, [])

        let http = RoutingHTTPClient { _ in
            XCTFail("xswap-managed credentials must not rotate")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let store = CodexAuthStore(
            environment: FakeEnvironment(environment), files: files, keychain: FakeKeychain(), now: { Self.now },
            expectedIdentity: cardB.identity, additionalAuthHomes: cardB.authHomes,
            writableAuthHomes: Set(cardB.writableAuthHomes), piCredentialSources: cardB.piCredentialSources
        )
        let snapshot = await provider(store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files["/test/slot-b/auth.json"], credential)
    }

    func testSwapMainHomeStaysReadOnlyWhenNoSlotNamesAnAccount() async throws {
        let files = FakeFiles([
            "/test/swap/accounts.json": #"{"schemaVersion":1,"mainHome":"/test/main","accounts":[{"number":1,"alias":"A","home":"/test/saved","identity":null}]}"#,
            "/test/main/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test"),
            "/test/.codex-work/auth.json": Fixtures.codexAuth(accountID: "B", email: "b@test"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CODEX_HOME": "/test/main", "XSWAP_HOME": "/test/swap"]), files: files,
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/test") }
        )

        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"], listCodexHomeDirectories: { $0 == "/test" ? [".codex-work"] : [] }
        )

        XCTAssertEqual(assembly.codexCards.count, 2)
        XCTAssertEqual(assembly.codexCards.first { $0.identity.accountID == "a" }?.writableAuthHomes, [])
        XCTAssertEqual(assembly.codexCards.first { $0.identity.accountID == "b" }?.writableAuthHomes, ["/test/.codex-work"])
    }

    func testLoneSiblingHomeOnThePlainCardRefreshesAndPersists() async throws {
        let files = FakeFiles([
            "/test/.codex-work/auth.json": Fixtures.codexAuth(accountID: "A", email: "a@test", accessToken: expired),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/test") }
        )
        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"], listCodexHomeDirectories: { $0 == "/test" ? [".codex-work"] : [] }
        )
        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.codex.plainWritableAuthHomes, ["/test/.codex-work"])

        let http = RoutingHTTPClient { [valid] request in
            request.url.host == "auth.openai.com" ? Self.refreshResponse(valid, refreshToken: "rt2") : Fixtures.usageResponse()
        }
        let store = CodexAuthStore(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(), now: { Self.now },
            additionalAuthHomes: assembly.codex.plainAuthHomes,
            writableAuthHomes: Set(assembly.codex.plainWritableAuthHomes),
            piCredentialSources: assembly.codex.plainPiCredentialSources
        )
        let snapshot = await provider(store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(files.files["/test/.codex-work/auth.json"])))
        XCTAssertEqual(saved.tokens?.refreshToken, "rt2")
    }

    /// A real directory tree so `resolvingSymlinksInPath` has something to resolve.
    private func makeScratchDirectory(_ directories: [String], links: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWritableHomeRefreshTests-\(UUID().uuidString)")
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        for (link, target) in links {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(link), withDestinationURL: root.appendingPathComponent(target)
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.path
    }
}

/// A file system whose writes fail, standing in for a read-only volume or a permissions error.
private struct UnwritableFiles: TextFileAccessing {
    struct WriteFailed: Error {}
    let files: FakeFiles

    init(_ files: FakeFiles) { self.files = files }
    func exists(_ path: String) -> Bool { files.exists(path) }
    func readText(_ path: String) throws -> String { try files.readText(path) }
    func writeText(_ path: String, _ text: String) throws { throw WriteFailed() }
    func remove(_ path: String) throws { throw WriteFailed() }
}
