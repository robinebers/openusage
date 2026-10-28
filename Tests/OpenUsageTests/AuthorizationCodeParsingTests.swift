import XCTest
@testable import OpenUsage

final class AuthorizationCodeParsingTests: XCTestCase {
    func testAPastedCodeWithItsStateIsAccepted() throws {
        XCTAssertEqual(try authorizationCode(from: .pasted("abc123#expected"), expectedState: "expected"), "abc123")
        XCTAssertEqual(try authorizationCode(from: .pasted("  abc123#expected\n"), expectedState: "expected"), "abc123")
    }

    func testAPastedCodeWithTheWrongOrAMissingStateIsRefused() {
        XCTAssertThrowsError(try authorizationCode(from: .pasted("abc123#other"), expectedState: "expected")) {
            XCTAssertEqual($0.localizedDescription, LoginError.invalidState.localizedDescription)
        }
        XCTAssertThrowsError(try authorizationCode(from: .pasted("abc123"), expectedState: "expected")) {
            XCTAssertEqual($0.localizedDescription, LoginError.invalidState.localizedDescription)
        }
    }

    func testABlankPasteIsAnInvalidCode() {
        XCTAssertThrowsError(try authorizationCode(from: .pasted("   "), expectedState: "expected")) {
            XCTAssertEqual($0.localizedDescription, LoginError.invalidCode.localizedDescription)
        }
    }

    func testAWholeCallbackURLIsReadForItsCodeAndState() throws {
        let callback = "http://127.0.0.1:1455/auth/callback?code=abc123&state=expected"
        XCTAssertEqual(try authorizationCode(from: .pasted(callback), expectedState: "expected"), "abc123")
        XCTAssertThrowsError(try authorizationCode(from: .pasted("http://127.0.0.1:1455/auth/callback?code=abc123&state=other"), expectedState: "expected")) {
            XCTAssertEqual($0.localizedDescription, LoginError.invalidState.localizedDescription)
        }
        XCTAssertThrowsError(try authorizationCode(from: .pasted("http://127.0.0.1:1455/auth/callback"), expectedState: "expected")) {
            XCTAssertEqual($0.localizedDescription, LoginError.invalidCode.localizedDescription)
        }
    }
}
