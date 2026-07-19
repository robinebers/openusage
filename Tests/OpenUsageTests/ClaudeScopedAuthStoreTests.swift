import XCTest
@testable import OpenUsage

/// The `.configDir` credential scope: an extra account card may only ever see its own login —
/// its own credentials file and its own computed keychain item, with no Desktop, environment-token,
/// or default-service fallback.
final class ClaudeScopedAuthStoreTests: XCTestCase {
    private let scope = ClaudeCredentialScope.configDir(
        path: "/Users/dev/.claude-work",
        keychainLiteral: "~/.claude-work"
    )

    func testScopedStoreReadsOnlyItsOwnCredentialSources() throws {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Another account's default-home file must stay invisible to the scoped card.
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [scopedService], "never the bare default service")
        let load = store.loadCredentialSet()
        XCTAssertEqual(load.candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertEqual(load.desktopStatus, .notChecked, "a config-dir card never consults Desktop")
    }

    func testScopedStoreNeverInheritsTheAmbientEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertFalse(candidates.contains { $0.source == .environment })
    }

    func testFootprintProbeSeesFileAndKeychainShapesWithoutReadingSecrets() {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let fileBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.claude-work/.credentials.json": "{}"]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertTrue(fileBacked.hasCredentialFootprint())

        let keychainBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(values: [scopedService: "present"]),
            scope: scope
        )
        XCTAssertTrue(keychainBacked.hasCredentialFootprint())

        let bare = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertFalse(bare.hasCredentialFootprint())
    }

    func testStandardStoreDropsDesktopFallbackWhileExtraCardsExistAndNoOrgPinIsKnown() {
        // With no CLI login, no org pin, and the unpinned fallback disallowed (extra Claude cards
        // exist), the load reports `.notFound` instead of consulting Desktop — the caller keeps the
        // honest CLI error.
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            allowsUnpinnedStandardDesktopFallback: false
        )

        let load = store.loadCredentialSet(forceDesktopFallback: true)
        XCTAssertEqual(load.desktopStatus, .notFound)
        XCTAssertTrue(load.candidates.isEmpty)
    }

    @MainActor
    func testACoworkPartitionAloneDisablesTheUnpinnedDesktopFallback() throws {
        // A distinct Cowork account can exist WITHOUT earning a card (no org pin, so no
        // Desktop-backed card is safe to build). Another account is still known on the machine,
        // so the default card's unpinned Desktop fallback must drop all the same — Desktop's
        // active org may be that account's usage pool.
        let partitioned = ProviderCatalog.make(defaultClaudeCoworkRoots: [])
        let claude = try XCTUnwrap(partitioned.compactMap { $0 as? ClaudeProvider }.first)
        XCTAssertFalse(claude.authStore.allowsUnpinnedStandardDesktopFallback)

        // Control: a machine with no other account known keeps the fallback.
        let alone = ProviderCatalog.make()
        let defaultClaude = try XCTUnwrap(alone.compactMap { $0 as? ClaudeProvider }.first)
        XCTAssertTrue(defaultClaude.authStore.allowsUnpinnedStandardDesktopFallback)
    }

    func testDesktopOnlyStoreHasNoCLISourcesAndNeverInheritsTheEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                // Every CLI credential on the machine must stay invisible to a Desktop-backed card.
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: .desktopOnly(organization: "11111111-2222-3333-4444-555555555555")
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [])
        // No Desktop material in this fixture, so the load ends up empty — the point is that no CLI
        // or environment candidate leaked in, and Desktop WAS consulted (status is not .notChecked).
        let load = store.loadCredentialSet()
        XCTAssertTrue(load.candidates.isEmpty)
        XCTAssertEqual(load.desktopStatus, .notFound)
    }
}
