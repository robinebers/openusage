import Foundation

/// Calls GitHub's internal Copilot usage endpoint with a GitHub OAuth token. Mirrors the headers the
/// official Copilot client sends; `Authorization` uses the `token` scheme (not `Bearer`), which is what
/// `/copilot_internal/user` accepts.
struct CopilotUsageClient: Sendable {
    var http: any HTTPClient

    func fetchUsage(token: String, domain: GitHubDomain) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: domain.apiURL("/copilot_internal/user"),
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

    static func organizationUsageURL(_ organization: String) -> URL {
        URL(string: "https://api.github.com/organizations")!
            .appending(components: organization, "settings", "billing", "ai_credit", "usage")
    }

    /// One organization's Copilot credits and spend this month, read with a token from an owner or
    /// billing manager of the organization: the Copilot sign-in itself cannot read organization billing.
    func organizationUsage(_ organization: String, token: String) async throws -> [MetricLine] {
        let response = try await LoginHTTP.get(Self.organizationUsageURL(organization), bearerToken: token, using: http, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "OpenUsage",
            "X-GitHub-Api-Version": "2022-11-28"
        ])
        if ProviderError.isAuthFailure(response) { throw ProviderError.keyRejected("GitHub rejected the token.") }
        if response.statusCode == 404 {
            throw ProviderError.unavailable("GitHub has no organization “\(organization)” this token can read.")
        }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
        guard let lines = CopilotOrgBillingMapper.usageLines(response) else { throw ProviderError.invalidResponse }
        return lines
    }
}
