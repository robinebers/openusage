import XCTest
@testable import OpenUsage

@MainActor
final class APIKeyV1FilesTests: XCTestCase {
    func testImportsEachSavedKeyAsAnAccountAndLeavesTheFilesAsTheyWere() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#, zai: #"{"apiKey":"zai-saved"}"#)
        let (store, vault) = makeStore()
        let defaults = isolatedDefaults()
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertEqual(store.accounts.map(\.kind), [.openrouter, .zai])
        XCTAssertEqual(store.accounts.map(\.label), ["OpenRouter", "Z.ai"])
        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, [.apiKey("sk-or-saved"), .apiKey("zai-saved")])
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/openusage/openrouter.json"), encoding: .utf8), #"{"apiKey":"sk-or-saved"}"#)
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/openusage/zai.json"), encoding: .utf8), #"{"apiKey":"zai-saved"}"#)
    }

    func testSkipsAProviderThatAlreadyHasAnAccount() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#)
        let (store, vault) = makeStore()
        let existing = store.add(kind: .openrouter, label: "Work", credential: .apiKey("sk-or-work"))
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(into: store, defaults: isolatedDefaults(), home: home, http: http)

        XCTAssertEqual(store.accounts.map(\.id), [existing.id])
        XCTAssertEqual(try vault.load(existing.id), .apiKey("sk-or-work"))
        XCTAssertTrue(http.requests.isEmpty, "a provider with an account sends no key check")
    }

    func testSkipsAKeyTheProviderRejects() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-revoked"}"#)
        let (store, _) = makeStore()
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }

        await APIKeyV1Files.importOnce(into: store, defaults: isolatedDefaults(), home: home, http: http)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer sk-or-revoked"])
    }

    func testAKeyCheckThatCouldNotReachTheProviderIsTriedAgainOnTheNextLaunch() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#)
        let (store, vault) = makeStore()
        let defaults = isolatedDefaults()
        let status = TestSwitch(503)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: status.value, headers: [:], body: Data(OpenRouterFixtures.standardKey.utf8)) }

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        XCTAssertTrue(store.accounts.isEmpty)

        status.value = 200
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(store.accounts.map(\.kind), [.openrouter])
        XCTAssertEqual(try vault.load(account.id), .apiKey("sk-or-saved"))
    }

    func testARemovedImportedAccountDoesNotComeBack() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#)
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        let http = acceptingHTTP()
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        let imported = try XCTUnwrap(store.accounts.first)
        store.remove(imported.id)
        let checks = http.requests.count

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(http.requests.count, checks, "a later launch reads no key and sends no check")
    }

    private func makeHome(openRouter: String? = nil, zai: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = home.appending(path: ".config/openusage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try openRouter?.write(to: folder.appending(path: "openrouter.json"), atomically: true, encoding: .utf8)
        try zai?.write(to: folder.appending(path: "zai.json"), atomically: true, encoding: .utf8)
        return home
    }

    private func makeStore() -> (AccountStore, InMemoryCredentialVault) {
        let vault = InMemoryCredentialVault()
        return (AccountStore(defaults: isolatedDefaults(), vault: vault), vault)
    }

    private func acceptingHTTP() -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            let body = request.url.host == "api.z.ai" ? Self.zaiQuota : OpenRouterFixtures.standardKey
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
    }

    private nonisolated static let zaiQuota = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1782724971179},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3,"nextResetTime":1783305486997},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0,"remaining":1000,"percentage":0,"nextResetTime":1785292686976,"usageDetails":[{"modelCode":"search-prime","usage":0},{"modelCode":"web-reader","usage":0},{"modelCode":"zread","usage":0}]}
    ],"level":"pro"},"success":true}
    """#
}
