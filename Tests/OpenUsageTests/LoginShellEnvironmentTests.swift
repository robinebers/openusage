import XCTest
@testable import OpenUsage

final class LoginShellEnvironmentTests: XCTestCase {
    private let begin = "__OPENUSAGE_ENV_BEGIN__"
    private let end = "__OPENUSAGE_ENV_END__"

    func testParsesKeysBetweenMarkers() {
        let output = [begin, "OPENROUTER_API_KEY=sk-or-v1-abc", "PATH=/usr/bin:/bin", end]
            .joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["OPENROUTER_API_KEY"], "sk-or-v1-abc")
        XCTAssertEqual(parsed["PATH"], "/usr/bin:/bin")
    }

    func testIgnoresBannerOutsideMarkers() {
        // A login shell can print an MOTD/banner before our command runs; it must not be parsed.
        let output = ["Welcome to your shell!", "MOTD=should-be-ignored\0" + begin,
                      "REAL=value", end, "trailing-noise"].joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["REAL"], "value")
        XCTAssertNil(parsed["MOTD"])
    }

    func testKeepsValuesContainingEquals() {
        let output = [begin, "TOKEN=a=b=c", end].joined(separator: "\0")
        XCTAssertEqual(LoginShellEnvironment.parse(output)["TOKEN"], "a=b=c")
    }

    func testMissingMarkersYieldEmpty() {
        XCTAssertTrue(LoginShellEnvironment.parse("PATH=/usr/bin\0HOME=/Users/x").isEmpty)
    }
}
