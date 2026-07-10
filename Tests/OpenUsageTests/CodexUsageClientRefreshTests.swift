import XCTest
@testable import OpenUsage

final class CodexUsageClientRefreshTests: XCTestCase {
    func testRefreshReportsRequestFailureForUnrecognizedErrorBody() async {
        // A 400 carrying a non-OAuth body (an HTML proxy/WAF page) must surface as a request failure,
        // not "Token expired. Run `codex` to log in again." — re-login can't fix a transport/infra error.
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8)))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(400))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshReportsRequestFailureForNon4xxStatus() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(503))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshStillMapsKnownOAuthCodeToSessionExpired() async {
        let body = Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: body))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexAuthError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("expected CodexAuthError.sessionExpired, got \(error)")
        }
    }
}
