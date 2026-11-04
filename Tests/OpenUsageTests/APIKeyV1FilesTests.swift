import Security
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
        XCTAssertEqual(store.accounts.map(\.label), ["OpenRouter Account", "Z.ai Account"])
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
        let defaults = isolatedDefaults()
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer sk-or-revoked"], "a rejected key is checked once")
    }

    func testSkipsAZaiKeyZaiRefusesInsideAnOKResponse() async throws {
        let home = try makeHome(zai: #"{"apiKey":"zai-expired"}"#)
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":401,"msg":"token expired or incorrect","success":false}"#.utf8))
        }

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(http.requests.filter { $0.url == ZAIUsageClient.quotaURL }.count, 1, "a refused key is checked once")
    }

    func testLeavesAProviderTheUserTurnedOffIn0716Off() async throws {
        let openRouterFile = #"{"apiKey":"sk-or-saved"}"#
        let home = try makeHome(openRouter: openRouterFile, zai: #"{"apiKey":"zai-saved"}"#)
        let (store, vault) = makeStore()
        let defaults = isolatedDefaults()
        defaults.set(["claude@aaaa1111", "zai"], forKey: "openusage.enabledProviders.v1")
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertEqual(store.accounts.map(\.kind), [.zai], "the enabled provider still imports")
        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, [.apiKey("zai-saved")])
        XCTAssertFalse(http.requests.contains { $0.url.host == "openrouter.ai" }, "a provider the user turned off sends no key check")
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/openusage/openrouter.json"), encoding: .utf8), openRouterFile)
    }

    func testLeavesAProviderOnAnOlderDisabledListOff() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#)
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        defaults.set(["openrouter"], forKey: "openusage.disabledProviders.v1")
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty, "a provider the user turned off sends no key check")
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

    func testAKeyTheKeychainRefusedIsAddedOnTheNextLaunch() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#)
        let vault = FailingVault()
        vault.saveError.value = KeychainVaultError.status(errSecInteractionNotAllowed)
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        let defaults = isolatedDefaults()
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        XCTAssertTrue(store.accounts.isEmpty)

        vault.saveError.value = nil
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(store.accounts.map(\.kind), [.openrouter])
        XCTAssertEqual(try vault.load(account.id), .apiKey("sk-or-saved"))
    }

    func testAZaiKeyWithNoActivePlanIsAddedOnTheLaunchAfterAPlanStarts() async throws {
        let home = try makeHome(zai: #"{"apiKey":"zai-saved"}"#)
        let (store, vault) = makeStore()
        let defaults = isolatedDefaults()
        let subscribed = TestSwitch(false)
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data((subscribed.value ? Self.zaiQuota : Self.zaiNoPlan).utf8))
        }

        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)
        XCTAssertTrue(store.accounts.isEmpty)

        subscribed.value = true
        await APIKeyV1Files.importOnce(into: store, defaults: defaults, home: home, http: http)

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(store.accounts.map(\.kind), [.zai])
        XCTAssertEqual(try vault.load(account.id), .apiKey("zai-saved"))
    }

    func testTheDevelopmentBuildLeavesTheSavedKeysAlone() async throws {
        let home = try makeHome(openRouter: #"{"apiKey":"sk-or-saved"}"#, zai: #"{"apiKey":"zai-saved"}"#)
        let (store, _) = makeStore()
        let http = acceptingHTTP()

        await APIKeyV1Files.importOnce(
            into: store, defaults: isolatedDefaults(), home: home, http: http, bundleIdentifier: "com.robinebers.openusage.dev"
        )

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty, "the development build sends no key check")
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

    private nonisolated static let zaiNoPlan = #"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#

    private nonisolated static let zaiQuota = #"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17}]},"success":true}"#
}
