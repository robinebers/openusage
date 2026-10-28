import XCTest
@testable import OpenUsageCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesTheProviderLowercased() throws {
        XCTAssertEqual(try CLIArguments.parse(["Codex"]).providerID, "codex")
        XCTAssertNil(try CLIArguments.parse([]).providerID)
    }

    func testParsesHelpAndVersionFlags() throws {
        XCTAssertTrue(try CLIArguments.parse(["-h"]).showHelp)
        XCTAssertTrue(try CLIArguments.parse(["--help"]).showHelp)
        XCTAssertTrue(try CLIArguments.parse(["-v"]).showVersion)
        XCTAssertTrue(try CLIArguments.parse(["--version"]).showVersion)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["--force"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }
}
