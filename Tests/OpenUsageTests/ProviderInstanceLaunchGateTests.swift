import XCTest
@testable import OpenUsage

final class ProviderInstanceLaunchGateTests: XCTestCase {
    func testShellTimeoutSkipsDiscoveryAndSuppressesPersistedInstances() {
        var ranDiscovery = false

        let result = ProviderInstanceLaunchGate.discover(shellEnvironmentReady: false) {
            ranDiscovery = true
            return ProviderInstanceDiscovery.Result()
        }

        XCTAssertFalse(ranDiscovery)
        XCTAssertEqual(result.basesWithUnreadableDefault, ["claude", "codex"])
        XCTAssertTrue(result.instances.isEmpty)
    }

    func testWarmShellRunsDiscovery() {
        var expected = ProviderInstanceDiscovery.Result()
        expected.defaultIdentityKeys["claude"] = ["account-a"]

        let result = ProviderInstanceLaunchGate.discover(shellEnvironmentReady: true) { expected }

        XCTAssertEqual(result.defaultIdentityKeys["claude"], ["account-a"])
        XCTAssertTrue(result.basesWithUnreadableDefault.isEmpty)
    }
}
