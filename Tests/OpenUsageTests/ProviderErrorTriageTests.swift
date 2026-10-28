import XCTest
@testable import OpenUsage

/// Covers `ProviderError.requireSuccess`, the shared non-2xx triage the Claude/Codex/Grok/Cursor
/// mappers route through: 401/403 → the account's sign-in expired, any other non-2xx → a request
/// failure carrying the status, and a 2xx returns without throwing.
final class ProviderErrorTriageTests: XCTestCase {
    private func requireSuccess(status: Int) throws {
        let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
        try ProviderError.requireSuccess(response, kind: .claude)
    }

    func testSuccessStatusesDoNotThrow() throws {
        for status in [200, 201, 204, 299] {
            try requireSuccess(status: status)
        }
    }

    func testUnauthorizedAndForbiddenThrowSignInExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? ProviderError, .signInExpired(.claude))
            }
        }
    }

    func testTooManyRequestsThrowsRateLimited() {
        XCTAssertThrowsError(try requireSuccess(status: 429)) { error in
            XCTAssertEqual(error as? ProviderError, .rateLimited(retryAfter: nil))
        }
    }

    func testOtherNon2xxThrowRequestFailedWithStatus() {
        for status in [400, 404, 500, 503] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? ProviderError, .requestFailed(status))
            }
        }
    }
}
