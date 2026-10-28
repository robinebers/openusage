import XCTest
@testable import OpenUsage

final class LogRedactionTests: XCTestCase {
    func testRedactLogMessageJWTAndBareApiKey() {
        let msg = "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U key=sk-1234567890abcdef"
        XCTAssertEqual(LogRedaction.redactLogMessage(msg), "token=[REDACTED] key=[REDACTED]")
    }

    func testRedactLogMessageAccountEqAndPaths() {
        let msg = "keychain read: service=Claude Code-credentials, account=rebers path=/opt/homebrew/bin/bunx home=/Users/rebers/.claude"
        XCTAssertEqual(
            LogRedaction.redactLogMessage(msg),
            "keychain read: service=Claude Code-credentials, account=[REDACTED] path=[PATH] home=[PATH]"
        )
    }
}
