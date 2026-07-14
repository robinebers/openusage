import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

final class ClaudeDesktopAuthStoreTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
    private let organization = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let otherOrganization = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let clientID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let otherClientID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private let password = "fixture-safe-storage-password"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecryptsElectronSafeStorageValue() throws {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let plaintext = Data(#"{"token":"secret"}"#.utf8)
        let encrypted = try encrypt(plaintext, key: key)

        XCTAssertEqual(try ClaudeDesktopAuthStore.decrypt(encrypted, key: key), plaintext)
        XCTAssertThrowsError(try ClaudeDesktopAuthStore.decrypt(Data("v11bad".utf8), key: key))
    }

    func testSelectsActiveOrganizationFromV2Cache() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("other-token", expiresIn: 7_200)
            ],
            v1: [
                cacheKey(organization: organization): tokenEntry("old-token", expiresIn: 10_800)
            ]
        )

        let result = fixture.store.load(allowInteraction: false)

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.oauth?.accessToken, "desktop-token")
        XCTAssertNil(result.oauth?.refreshToken)
        XCTAssertEqual(result.oauth?.scopes, ["user:profile", "user:inference"])
    }

    func testV1FallbackDoesNotOverrideTombstonedV2Key() throws {
        let key = cacheKey(organization: organization)
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [key: NSNull()],
            v1: [key: tokenEntry("resurrected-token", expiresIn: 3_600)],
            now: now
        )

        guard case .notFound = selection else {
            return XCTFail("V2 tombstone should suppress the matching V1 token")
        }
    }

    func testFullScopeProductionClientOutranksLongerLivedProfileOnlyEntry() throws {
        // Two live entries under the same org: a long-TTL profile-only leftover carrying a stale 5x
        // tier, and the current full-scope Claude Code production login (20x) expiring sooner. Expiry
        // alone would pick the stale 5x token; the ranking must pick the production login.
        let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("stale-5x-token", expiresIn: 86_400, rateLimitTier: "default_claude_max_5x"),
                cacheKey(
                    organization: organization,
                    clientID: productionClientID,
                    scopes: "user:profile user:inference"
                ):
                    tokenEntry("current-20x-token", expiresIn: 1_800, rateLimitTier: "default_claude_max_20x")
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "current-20x-token")
        XCTAssertEqual(oauth.rateLimitTier, "default_claude_max_20x")
    }

    func testFullScopeEntryOutranksProfileOnlyEntryForNonProductionClients() throws {
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("profile-only-token", expiresIn: 86_400),
                cacheKey(organization: organization, clientID: otherClientID, scopes: "user:profile user:inference"):
                    tokenEntry("full-scope-token", expiresIn: 1_800)
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "full-scope-token")
    }

    func testBackgroundReadDoesNotPromptButManualReadCan() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .permissionRequired)
        XCTAssertEqual(fixture.keyReader.calls, [false])
        XCTAssertEqual(fixture.store.load(allowInteraction: true).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, true])

        // The derived key is cached after approval, so later background refreshes are prompt-free.
        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, true])
    }

    func testExpiredDesktopTokenIsStale() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired", expiresIn: -1)]
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .stale)
    }

    func testWorkingCLICredentialsSkipDesktopProbe() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: fixture.files,
            keychain: FakeKeychain(
                #"{"claudeAiOauth":{"accessToken":"cli-token","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            ),
            desktop: fixture.store,
            now: { now }
        )

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "cli-token")
        XCTAssertEqual(load.desktopStatus, .notChecked)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testWhitespaceOnlyCLIEntryDoesNotBlockDesktop() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: fixture.files,
            keychain: FakeKeychain(
                #"{"claudeAiOauth":{"accessToken":"   ","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            ),
            desktop: fixture.store,
            now: { now }
        )

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.source, .desktop)
        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "desktop-token")
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    @MainActor
    func testDesktopPermissionIsNotMaskedByScopedCLIToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )
        let now = now
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"inference-only-cli","expiresAt":4102444800000,"scopes":["user:inference"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.desktopPermissionRequired.localizedDescription)
        XCTAssertTrue(httpClient.requests.isEmpty)
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    func testDesktopCredentialsAreNeverSaved() throws {
        let files = FakeFiles()
        let keychain = FakeKeychain()
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: files,
            keychain: keychain,
            desktop: fixture.store,
            now: { now }
        )
        let state = authStore.loadCredentialCandidates().first!

        XCTAssertFalse(try authStore.save(state, ifUnchanged: ClaudeCredentialGeneration([state])))
        XCTAssertTrue(files.files.isEmpty)
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testDesktop401NeverAttemptsRefreshTokenExchange() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: fixture.files,
                keychain: FakeKeychain(),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.desktopTokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    @MainActor
    func testRevokedCLILoginFallsBackToDesktop() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            if authorization.contains("desktop-token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertTrue(httpClient.requests.last?.headers["Authorization"]?.contains("desktop-token") == true)
    }

    @MainActor
    func testRevokedCLILoginTriesDesktopBeforeEnvironmentToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            if authorization.contains("desktop-token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment([
                    "CLAUDE_CONFIG_DIR": "/tmp/claude",
                    "CLAUDE_CODE_OAUTH_TOKEN": "inference-only-env"
                ]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertTrue(httpClient.requests.last?.headers["Authorization"]?.contains("desktop-token") == true)
    }

    @MainActor
    func testStaleDesktopDoesNotMaskRevokedCLIError() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired-desktop", expiresIn: -1)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    private func makeFixture(
        activeOrganization: String,
        v2: [String: Any],
        v1: [String: Any]? = nil,
        requiresInteraction: Bool = false
    ) throws -> DesktopFixture {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let cookieHost = ".claude.ai"
        let cookiePlaintext = Data(SHA256.hash(data: Data(cookieHost.utf8))) + Data(activeOrganization.utf8)
        let encryptedCookie = try encrypt(cookiePlaintext, key: key)
        let v2Data = try JSONSerialization.data(withJSONObject: v2)
        let encryptedV2 = try encrypt(v2Data, key: key)
        var config: [String: Any] = ["oauth:tokenCacheV2": encryptedV2.base64EncodedString()]
        if let v1 {
            let v1Data = try JSONSerialization.data(withJSONObject: v1)
            config["oauth:tokenCache"] = try encrypt(v1Data, key: key).base64EncodedString()
        }
        let configText = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let configPath = home.appendingPathComponent("Library/Application Support/Claude/config.json").path
        let cookiesPath = home.appendingPathComponent("Library/Application Support/Claude/Cookies").path
        let files = FakeFiles([configPath: configText, cookiesPath: "sqlite-fixture"])
        let sqlite = FakeClaudeDesktopSQLite(value: "encrypted:\(hex(encryptedCookie))")
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: requiresInteraction)
        let fixtureHome = home
        let fixtureNow = now
        let store = ClaudeDesktopAuthStore(
            files: files,
            sqlite: sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        return DesktopFixture(store: store, files: files, keyReader: keyReader)
    }

    private func cacheKey(
        organization: String,
        clientID: String? = nil,
        scopes: String = "user:profile user:inference"
    ) -> String {
        "\(clientID ?? self.clientID):\(organization):https://api.anthropic.com:\(scopes)"
    }

    private func tokenEntry(
        _ token: String,
        expiresIn seconds: TimeInterval,
        rateLimitTier: String = "default"
    ) -> [String: Any] {
        [
            "token": token,
            "expiresAt": (now.timeIntervalSince1970 + seconds) * 1000,
            "subscriptionType": "max",
            "rateLimitTier": rateLimitTier
        ]
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        return Data("v10".utf8) + output
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }
}

private struct DesktopFixture {
    var store: ClaudeDesktopAuthStore
    var files: FakeFiles
    var keyReader: FakeClaudeDesktopKeyReader
}

private final class FakeClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let password: String
    let requiresInteraction: Bool
    var calls: [Bool] = []

    init(password: String, requiresInteraction: Bool) {
        self.password = password
        self.requiresInteraction = requiresInteraction
    }

    func readPassword(allowInteraction: Bool) throws -> String? {
        calls.append(allowInteraction)
        if requiresInteraction, !allowInteraction {
            throw ClaudeDesktopCredentialError.permissionRequired
        }
        return password
    }
}

private final class FakeClaudeDesktopSQLite: SQLiteAccessing, @unchecked Sendable {
    let value: String?

    init(value: String?) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        value
    }

    func execute(path: String, sql: String) throws {}
}
