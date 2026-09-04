import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

extension ClaudeDesktopAuthStoreTests {
    /// The stock CLI keychain payload: one far-future OAuth token with the given scope.
    func cliCredentials(token: String, scope: String = "user:profile") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["\#(scope)"]}}"#
    }

    func makeAuthStore(
        _ fixture: DesktopFixture,
        environment: [String: String] = ["CLAUDE_CONFIG_DIR": "/tmp/claude"],
        keychainJSON: String? = nil,
        files: FakeFiles? = nil,
        keychain: (any KeychainAccessing)? = nil
    ) -> ClaudeAuthStore {
        let now = now
        return ClaudeAuthStore(
            environment: FakeEnvironment(environment),
            files: files ?? fixture.files,
            keychain: keychain ?? FakeKeychain(keychainJSON),
            desktop: fixture.store,
            now: { now }
        )
    }

    @MainActor
    func makeProvider(
        _ fixture: DesktopFixture,
        environment: [String: String] = ["CLAUDE_CONFIG_DIR": "/tmp/claude"],
        keychainJSON: String?,
        httpClient: any HTTPClient
    ) -> ClaudeProvider {
        let now = now
        return ClaudeProvider(
            authStore: makeAuthStore(fixture, environment: environment, keychainJSON: keychainJSON),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    func makeFixture(
        activeOrganization: String,
        v2: [String: Any],
        v1: [String: Any]? = nil,
        requiresInteraction: Bool = false,
        accountUUID: String? = nil
    ) throws -> DesktopFixture {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let cookieHost = ".claude.ai"
        let cookiePlaintext = Data(SHA256.hash(data: Data(cookieHost.utf8))) + Data(activeOrganization.utf8)
        let encryptedCookie = try encrypt(cookiePlaintext, key: key)
        let v2Data = try JSONSerialization.data(withJSONObject: v2)
        let encryptedV2 = try encrypt(v2Data, key: key)
        var config: [String: Any] = ["oauth:tokenCacheV2": encryptedV2.base64EncodedString()]
        if let accountUUID { config["lastKnownAccountUuid"] = accountUUID }
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

    func cacheKey(
        organization: String,
        clientID: String? = nil,
        scopes: String = "user:profile user:inference"
    ) -> String {
        "\(clientID ?? self.clientID):\(organization):https://api.anthropic.com:\(scopes)"
    }

    func tokenEntry(
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

    func encrypt(_ plaintext: Data, key: Data) throws -> Data {
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

    func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }}


struct DesktopFixture {
    var store: ClaudeDesktopAuthStore
    var files: FakeFiles
    var keyReader: FakeClaudeDesktopKeyReader
}

final class FakeClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
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

final class FakeClaudeDesktopSQLite: SQLiteAccessing, @unchecked Sendable {
    let value: String?

    init(value: String?) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        value
    }

    func execute(path: String, sql: String) throws {}
}
