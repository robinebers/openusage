import XCTest
@testable import OpenUsage

/// The config-dir candidate rules: identity-extraction-is-validation plus the exact credential
/// shape, with the default homes excluded. Everything runs on fakes — no real filesystem/keychain.
final class ClaudeConfigDirDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func makeDiscovery(
        environment: [String: String] = [:],
        files: [String: String],
        keychainServices: [String: String] = [:],
        subdirectories: [String] = []
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: ServiceKeychain(values: keychainServices),
            homeDirectory: { [home] in home },
            listSubdirectories: { [home] url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
                    .filter { _ in url.path.hasPrefix(home.path) }
            }
        )
    }

    func testAcceptsADirWithIdentityAndFileCredential() throws {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let result = discovery.run()

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(finding.identityKey, "acct-2")
        XCTAssertEqual(finding.label, "work@example.com (Sunstory)")
        XCTAssertEqual(finding.anchorPath, "/Users/dev/.claude-work")
    }

    func testAcceptsAKeychainBackedDirThroughItsScopedServiceName() throws {
        // Claude Code hashes the literal CLAUDE_CONFIG_DIR string; the `~` spelling must be probed
        // alongside the absolute one, and the matched literal is what the scoped store reuses.
        let literal = "~/.claude-alt"
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: literal, environment: FakeEnvironment([:])
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-alt/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-3"}}"#,
            ],
            keychainServices: [service: "present"],
            subdirectories: ["/Users/dev/.claude-alt"]
        )

        let result = discovery.run()

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.identityKey, "acct-3")
        XCTAssertEqual(finding.keychainLiteral, literal)
    }

    func testRejectsIdentityWithoutCredentialAndCredentialWithoutIdentity() {
        let discovery = makeDiscovery(
            files: [
                // Identity but no credential shape: a toy/fork state file.
                "/Users/dev/.claude-toy/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-4"}}"#,
                // Credential but no identity: can't be routed to an account, must not become a card.
                "/Users/dev/.claude-anon/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-5"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-toy", "/Users/dev/.claude-anon"]
        )

        let result = discovery.run()

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.notes.count, 1, "the near-miss with an identity enters the support trail")
    }

    func testExcludesTheDefaultHomesIncludingTheEnvOverride() {
        let files = [
            "/Users/dev/.claude-main/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-MAIN"}}"#,
            "/Users/dev/.claude-main/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at"}}"#,
            "/Users/dev/.config/claude/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-XDG"}}"#,
            "/Users/dev/.config/claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at"}}"#,
        ]
        let discovery = makeDiscovery(
            environment: ["CLAUDE_CONFIG_DIR": "~/.claude-main"],
            files: files,
            subdirectories: ["/Users/dev/.claude-main", "/Users/dev/.config/claude"]
        )

        // The env-named home is the default card's and is excluded; the XDG dir is then a genuinely
        // separate home and a legitimate candidate.
        XCTAssertEqual(discovery.run().findings.map(\.identityKey), ["acct-xdg"])

        // Without the override, XDG is a default home again and the env-named dir is the candidate.
        let withoutOverride = makeDiscovery(
            files: files,
            subdirectories: ["/Users/dev/.claude-main", "/Users/dev/.config/claude"]
        )
        XCTAssertEqual(withoutOverride.run().findings.map(\.identityKey), ["acct-main"])
    }
}
