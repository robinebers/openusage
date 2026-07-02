import XCTest
@testable import OpenUsage

final class ClaudeProfileTests: XCTestCase {
    func testReadsEmailFromProfileAccount() {
        let json = Data(#"{"account":{"uuid":"x","email":"jordan@westlinemarketing.com"},"organization":{}}"#.utf8)
        XCTAssertEqual(ClaudeProfile.email(fromProfileResponse: json), "jordan@westlinemarketing.com")
    }

    func testReturnsNilWhenMissingOrInvalid() {
        XCTAssertNil(ClaudeProfile.email(fromProfileResponse: Data(#"{"organization":{}}"#.utf8)))
        XCTAssertNil(ClaudeProfile.email(fromProfileResponse: Data(#"{"account":{"email":"nope"}}"#.utf8)))
        XCTAssertNil(ClaudeProfile.email(fromProfileResponse: Data("not json".utf8)))
    }
}
