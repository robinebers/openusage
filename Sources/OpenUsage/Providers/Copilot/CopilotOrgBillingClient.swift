import Foundation

/// Calls GitHub's public REST billing endpoints to find the organization that provides an org-managed
/// Copilot seat and read its month-to-date usage. Used only when `/copilot_internal/user` reports a
/// token-based-billing seat with no per-seat quota (Copilot Business/Enterprise managed by an org) —
/// the usage then lives in *organization* billing, which the user-scoped endpoint never carries.
///
/// Reading an org's billing requires the caller to be an org owner or billing manager; a plain member
/// gets 403. That's an expected state, handled by the provider, not an error here.
struct CopilotOrgBillingClient: Sendable {
    static let userOrgsURL = "https://api.github.com/user/orgs?per_page=100"

    static func usageSummaryURL(org: String) -> URL? {
        // Org slugs are alphanumeric-plus-hyphen, but encode defensively before splicing into the path.
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The organizations the token's user belongs to (first page, 100 max — plenty for this purpose).
    func fetchUserOrgs(token: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.userOrgsURL) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    /// Month-to-date billing usage summary for one organization.
    func fetchUsageSummary(org: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.usageSummaryURL(org: org) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    private func send(url: URL, token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/vnd.github+json",
                "User-Agent": "OpenUsage",
                "X-GitHub-Api-Version": "2022-11-28"
            ],
            timeout: 15
        ))
    }
}
