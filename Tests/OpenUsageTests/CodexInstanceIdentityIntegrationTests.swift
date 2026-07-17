import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexInstanceIdentityIntegrationTests: XCTestCase {
    func testKeyringOnlyDiscoveryUsesCachedAccountIdentities() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let defaultHome = home.appendingPathComponent(".codex")
        let workHome = home.appendingPathComponent(".codex-work")
        for directory in [defaultHome, workHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "model = \"gpt-5\"".write(
                to: directory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let keychain = AccountAwareKeychain()
        for directory in [defaultHome, workHome] {
            let account = CodexAuthStore.keychainAccountName(forHome: directory.path)
            keychain.existingItems.insert("Codex Auth|\(account)")
        }
        let cache = MemoryCodexIdentityCache([
            defaultHome.path: "acct-default",
            workHome.path: "acct-work"
        ])

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { home }
        ).run()

        XCTAssertEqual(result.defaultIdentityKeys["codex"], ["acct-default"])
        XCTAssertFalse(result.basesWithUnreadableDefault.contains("codex"))
        XCTAssertEqual(result.instances.first { $0.baseProviderID == "codex" }?.identityKey, "acct-work")
    }

    func testChangedExtraKeyringItemInvalidatesCacheUntilRuntimeReadRefreshesIt() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-stale-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let defaultHome = home.appendingPathComponent(".codex")
        let extraHome = home.appendingPathComponent(".codex-work")
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"at","account_id":"acct-default"}}"#.write(
            to: defaultHome.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8
        )
        try "model = \"gpt-5\"".write(
            to: extraHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let keychain = AccountAwareKeychain()
        let account = CodexAuthStore.keychainAccountName(forHome: extraHome.path)
        let itemKey = "\(CodexAuthStore.keychainService)|\(account)"
        keychain.existingItems.insert(itemKey)
        keychain.attributeFingerprints[itemKey] = "item-version-b"

        let suite = "OpenUsageTests.CodexStaleIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = CodexHomeIdentityCache(defaults: defaults)
        cache.record(
            identityKey: "acct-old",
            forHome: extraHome.path,
            keychainItemFingerprint: "item-version-a"
        )

        let stale = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { home }
        ).run()

        XCTAssertTrue(stale.unverifiedCodexKeyringHomes.contains(
            ProviderInstanceID.canonicalHomePath(extraHome.path)
        ))
        XCTAssertTrue(
            stale.instances.contains {
                $0.anchorPath.map(ProviderInstanceID.canonicalHomePath)
                    == ProviderInstanceID.canonicalHomePath(extraHome.path)
                    && ProviderInstanceID.isPathDerivedKey($0.identityKey)
            },
            "the stale account id must not survive an item-attribute change"
        )

        // Model the retained account-scoped runtime read: it learns the replacement account and binds
        // it to the current item fingerprint. The next launch folds that home into the default card
        // and retains its logs, rather than rendering a duplicate instance.
        cache.record(
            identityKey: "acct-default",
            forHome: extraHome.path,
            keychainItemFingerprint: "item-version-b"
        )
        let warmed = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { home }
        ).run()

        XCTAssertFalse(warmed.unverifiedCodexKeyringHomes.contains(
            ProviderInstanceID.canonicalHomePath(extraHome.path)
        ))
        XCTAssertFalse(warmed.instances.contains {
            $0.anchorPath.map(ProviderInstanceID.canonicalHomePath)
                == ProviderInstanceID.canonicalHomePath(extraHome.path)
        })
        XCTAssertEqual(
            warmed.foldedInstancesForReconciliation.first {
                $0.anchorPath.map(ProviderInstanceID.canonicalHomePath)
                    == ProviderInstanceID.canonicalHomePath(extraHome.path)
            }?.identityKey,
            "acct-default"
        )
        XCTAssertEqual(warmed.codexLogRootsByIdentityKey["acct-default"]?.count, 2)
    }

    func testUnverifiedHigherPrecedenceDefaultHomeSuppressesCodexInstancesAndQueuesWarm() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-default-precedence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let firstDefault = home.appendingPathComponent(".config/codex")
        let secondDefault = home.appendingPathComponent(".codex")
        let extra = home.appendingPathComponent(".codex-work")
        for directory in [firstDefault, secondDefault] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "model = \"gpt-5\"".write(
                to: directory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"at","account_id":"acct-extra"}}"#.write(
            to: extra.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8
        )

        let keychain = AccountAwareKeychain()
        for directory in [firstDefault, secondDefault] {
            let account = CodexAuthStore.keychainAccountName(forHome: directory.path)
            keychain.existingItems.insert("Codex Auth|\(account)")
        }
        let cache = MemoryCodexIdentityCache([secondDefault.path: "acct-second"])

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { home }
        ).run()

        XCTAssertTrue(result.basesWithUnreadableDefault.contains("codex"))
        XCTAssertTrue(result.instances.filter { $0.baseProviderID == "codex" }.isEmpty)
        XCTAssertTrue(result.unverifiedCodexKeyringHomes.contains(
            ProviderInstanceID.canonicalHomePath(firstDefault.path)
        ))
        XCTAssertEqual(result.defaultIdentityKeys["codex"], ["acct-second"])
    }

    func testDefaultFileAndKeychainIdentityDisagreementSuppressesCodexInstances() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-mixed-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let defaultHome = home.appendingPathComponent(".codex")
        let extraHome = home.appendingPathComponent(".codex-work")
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"file-token","account_id":"acct-file"}}"#.write(
            to: defaultHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        try #"{"tokens":{"access_token":"extra-token","account_id":"acct-keychain"}}"#.write(
            to: extraHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        let keychain = AccountAwareKeychain()
        let account = CodexAuthStore.keychainAccountName(forHome: defaultHome.path)
        keychain.existingItems.insert("Codex Auth|\(account)")
        let cache = MemoryCodexIdentityCache([defaultHome.path: "acct-keychain"])

        let result = ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { home }
        ).run()

        XCTAssertTrue(result.basesWithUnreadableDefault.contains("codex"))
        XCTAssertNil(result.defaultIdentityKeys["codex"])
        XCTAssertFalse(result.instances.contains { $0.baseProviderID == "codex" })
    }

    func testCatalogRelaysResolvedCodexIdentityByCardID() throws {
        let instance = ProviderInstanceRecord(
            id: "codex@work",
            baseProviderID: "codex",
            ordinal: 2,
            kind: .codexHome,
            anchorPath: "/Users/x/.codex-work",
            keychainLiteral: nil,
            identityKey: "pending-work",
            identityLabel: nil
        )
        let recorder = CodexCardIdentityRecorder()
        let runtimes = ProviderCatalog.make(
            instanceContext: ProviderInstanceContext(records: [instance]),
            codexIdentityDidResolve: { providerID, identityKey in
                recorder.record(providerID: providerID, identityKey: identityKey)
            }
        )
        let defaultCodex = try XCTUnwrap(runtimes.first { $0.provider.id == "codex" } as? CodexProvider)
        let workCodex = try XCTUnwrap(runtimes.first { $0.provider.id == instance.id } as? CodexProvider)

        defaultCodex.identityDidResolve?("acct-default")
        workCodex.identityDidResolve?("acct-work")

        XCTAssertEqual(recorder.snapshot(), ["codex": "acct-default", instance.id: "acct-work"])
    }
}

private final class MemoryCodexIdentityCache: CodexHomeIdentityCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map {
            (ProviderInstanceID.canonicalHomePath($0.key), $0.value)
        })
    }

    func identityKey(forHome path: String, keychainItemFingerprint: String) -> String? {
        lock.withLock { values[ProviderInstanceID.canonicalHomePath(path)] }
    }

    func record(identityKey: String, forHome path: String, keychainItemFingerprint: String) {
        lock.withLock { values[ProviderInstanceID.canonicalHomePath(path)] = identityKey }
    }
}

private final class CodexCardIdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func record(providerID: String, identityKey: String) {
        lock.withLock { values[providerID] = identityKey }
    }

    func snapshot() -> [String: String] {
        lock.withLock { values }
    }
}
