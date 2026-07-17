import XCTest
@testable import OpenUsage

@MainActor
final class ProviderRuntimeAssemblyTests: XCTestCase {
    func testAssemblyBuildsDiscoveredInstancesForOneShotConsumers() {
        let defaults = makeScratchDefaults()
        let instanceID = ProviderInstanceID.make(
            baseProviderID: "claude",
            identityKey: "account-secondary|org-secondary"
        )
        var discovery = ProviderInstanceDiscovery.Result()
        discovery.instances = [
            DiscoveredProviderInstance(
                baseProviderID: "claude",
                kind: .claudeConfigDir,
                anchorPath: "/Users/test/.claude-secondary",
                keychainLiteral: "~/.claude-secondary",
                identityKey: "account-secondary|org-secondary",
                identityLabel: "secondary@example.com"
            )
        ]
        discovery.defaultIdentityKeys = [
            "claude": ["account-primary|org-primary"]
        ]

        let assembly = ProviderRuntimeAssembly.make(
            defaults: defaults,
            shellEnvironmentReady: true,
            discovery: { _ in discovery }
        )

        XCTAssertEqual(
            Array(assembly.providers.map(\.provider.id).prefix(3)),
            ["claude", instanceID, "codex"]
        )
        XCTAssertEqual(assembly.providers[0].provider.displayName, "Claude 1")
        XCTAssertEqual(assembly.providers[1].provider.displayName, "Claude 2")
        XCTAssertEqual(
            assembly.providerIdentityKeys,
            [
                "claude": "account-primary|org-primary",
                instanceID: "account-secondary|org-secondary"
            ]
        )
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderRuntimeAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
