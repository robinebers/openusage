import XCTest
@testable import OpenUsage

@MainActor
final class AccountProvidersTests: XCTestCase {
    func testExpandsClaudeAndCodexInstancesWithUniqueIDs() {
        let accounts = [
            ExtraAccount(provider: "claude", slot: "work", label: "Work", configDir: "/tmp/claude-work"),
            ExtraAccount(provider: "codex", slot: "alt", label: "Alt", configDir: "/tmp/codex-alt")
        ]
        let extras = AccountProviders.extraProviders(for: accounts)
        let registry = WidgetRegistry.from([ClaudeProvider(), CodexProvider()] + extras)

        // Extra instances register under unique ids and labeled display names.
        XCTAssertNotNil(registry.provider(id: "claude@work"))
        XCTAssertEqual(registry.provider(id: "claude@work")?.displayName, "Claude · Work")
        XCTAssertNotNil(registry.provider(id: "codex@alt"))
        XCTAssertEqual(registry.provider(id: "codex@alt")?.displayName, "Codex · Alt")

        // The default accounts keep their original ids (no settings migration).
        XCTAssertNotNil(registry.provider(id: "claude"))
        XCTAssertNotNil(registry.descriptor(id: "claude.session"))

        // Extra accounts get prefixed descriptor ids and the same metric set as that
        // provider's default account — assert against the default's count rather than a
        // fixed number, so this stays correct as providers gain or lose widgets upstream.
        XCTAssertNotNil(registry.descriptor(id: "claude@work.session"))
        XCTAssertEqual(registry.descriptors(for: "claude@work").count,
                       registry.descriptors(for: "claude").count)
        XCTAssertEqual(registry.descriptors(for: "codex@alt").count,
                       registry.descriptors(for: "codex").count)
    }

    func testSkipsProvidersThatCannotMultiAccount() {
        let accounts = [ExtraAccount(provider: "cursor", slot: "x", label: "X", configDir: "/tmp/x")]
        XCTAssertTrue(AccountProviders.extraProviders(for: accounts).isEmpty)
    }
}
