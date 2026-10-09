import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeConfigDirectoryAccountTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/config-test")

    func testConfigFolderBecomesItsOwnCardReadingItsPathScopedKeychainItem() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"11111111-1111-1111-1111-111111111111","organizationUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","emailAddress":"main@example.com"}}"#,
            home.path + "/.claude-work/.claude.json":
                #"{"oauthAccount":{"accountUuid":"22222222-2222-2222-2222-222222222222","organizationUuid":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","emailAddress":"work@example.com","organizationName":"Work Org"}}"#
        ])
        let suite = "ClaudeConfigDirTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = DefaultAccountObserver(environment: FakeEnvironment([:]), files: files,
                                              keychain: FakeKeychain(), homeDirectory: { [home] in home })
        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults),
            listHomeEntries: { _ in [".claude", ".claude-work", ".claude-empty", ".claude-swap-backup", ".zshrc"] }
        )

        let work = try XCTUnwrap(assembly.claudeCards.first { $0.swapAccount?.email == "work@example.com" })
        XCTAssertEqual(work.displayName, "Claude: Work Org (work@example.com)")
        XCTAssertEqual(work.swapAccount?.sessionDirectory, home.path + "/.claude-work")
        XCTAssertEqual(assembly.claudeCards.count, 2)

        let store = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(),
                                    swapAccount: work.swapAccount)
        // Claude Code names the item after the first 8 hex chars of sha256(path).
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-credentials-f3d833ee"])
        XCTAssertNil(store.loadSwapVaultCredential(try XCTUnwrap(work.swapAccount)))
    }
}
