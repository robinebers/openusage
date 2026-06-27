import Foundation

/// Calls GitHub's internal Copilot usage endpoint with a GitHub OAuth token. Mirrors the headers the
/// official Copilot client sends; `Authorization` uses the `token` scheme (not `Bearer`), which is what
/// `/copilot_internal/user` accepts.
struct CopilotUsageClient: Sendable {
    static let usageURL = "https://api.github.com/copilot_internal/user"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(token: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.usageURL) else {
            throw CopilotUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/json",
                "Editor-Version": "vscode/1.96.2",
                "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7",
                "X-Github-Api-Version": "2025-04-01"
            ],
            timeout: 15
        ))
    }
}
