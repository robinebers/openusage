import XCTest
@testable import OpenUsage

/// The transport's log line is built from the request method, the URL's host and path, the status,
/// and the duration. A Cursor poll carries the PKCE verifier in its query and a failed poll echoes it
/// in the error body; neither may appear, and neither may a header.
final class HTTPClientDiagnosticTests: XCTestCase {
    func testDiagnosticCarriesOnlyMethodEndpointStatusAndDuration() throws {
        let verifier = "SYNTHETIC-pkce-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
        var poll = try XCTUnwrap(URLComponents(string: "https://api2.cursor.sh/auth/poll"))
        poll.queryItems = [
            URLQueryItem(name: "uuid", value: "7f3c2a90"),
            URLQueryItem(name: "verifier", value: verifier),
        ]
        let request = HTTPRequest(
            method: "GET",
            url: try XCTUnwrap(poll.url),
            headers: ["Authorization": "Bearer SYNTHETIC-bearer-token"]
        )
        let response = HTTPResponse(
            statusCode: 401,
            headers: ["set-cookie": "SYNTHETIC-session-cookie"],
            body: Data(#"{"error":"invalid verifier \#(verifier)","detail":"SYNTHETIC-ERROR-BODY"}"#.utf8)
        )

        let line = URLSessionHTTPClient.diagnostic(for: request, response: response, duration: .milliseconds(143))

        XCTAssertEqual(line, "GET api2.cursor.sh/auth/poll -> 401 (143 ms)")
    }
}
