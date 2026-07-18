import XCTest
@testable import OpenUsageCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndForce() throws {
        let parsed = try CLIArguments.parse(["Codex", "--force"])
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.force)
    }

    func testParsesClaimReset() throws {
        let parsed = try CLIArguments.parse(["codex", "--claim-reset"])
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.claimReset)
        XCTAssertFalse(try CLIArguments.parse(["codex"]).claimReset)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }
}
