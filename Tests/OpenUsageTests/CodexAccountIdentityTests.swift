import XCTest
@testable import OpenUsage

final class CodexAccountIdentityTests: XCTestCase {
    /// Builds a JWT-shaped `header.payload.signature` string with the given payload JSON, base64url
    /// encoded with padding stripped — exactly how real OIDC id_tokens are shaped.
    private func makeIDToken(payload: String) -> String {
        func base64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64url("{\"alg\":\"RS256\"}")).\(base64url(payload)).signature"
    }

    func testExtractsEmailFromIDTokenPayload() {
        let token = makeIDToken(payload: "{\"email\":\"dev@example.com\",\"email_verified\":true}")
        XCTAssertEqual(CodexAccountIdentity.email(fromIDToken: token), "dev@example.com")
    }

    func testReturnsNilWhenNoEmailClaim() {
        let token = makeIDToken(payload: "{\"sub\":\"abc123\"}")
        XCTAssertNil(CodexAccountIdentity.email(fromIDToken: token))
    }

    func testReturnsNilForMalformedOrMissingToken() {
        XCTAssertNil(CodexAccountIdentity.email(fromIDToken: "not-a-jwt"))
        XCTAssertNil(CodexAccountIdentity.email(fromIDToken: ""))
        XCTAssertNil(CodexAccountIdentity.email(fromIDToken: nil))
    }
}
