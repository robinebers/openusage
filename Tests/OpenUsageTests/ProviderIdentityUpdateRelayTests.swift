import XCTest
@testable import OpenUsage

@MainActor
final class ProviderIdentityUpdateRelayTests: XCTestCase {
    func testBuffersLatestIdentityUntilSinkIsInstalled() {
        let relay = ProviderIdentityUpdateRelay()
        relay.submit(providerID: "codex@abcd1234", identityKey: "account-a")
        relay.submit(providerID: "codex@abcd1234", identityKey: "account-b")
        var received: [(String, String)] = []
        relay.install { received.append(($0, $1)) }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "codex@abcd1234")
        XCTAssertEqual(received.first?.1, "account-b")
    }

    func testForwardsIdentityAfterSinkInstallation() {
        let relay = ProviderIdentityUpdateRelay()
        var received: [(String, String)] = []
        relay.install { received.append(($0, $1)) }

        relay.submit(providerID: "codex", identityKey: "account-a")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "codex")
        XCTAssertEqual(received.first?.1, "account-a")
    }
}
