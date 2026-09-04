import Foundation

/// Calls OpenCode's official Go usage endpoint with the local `opencode-go` API key.
struct OpenCodeUsageClient: Sendable {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}
