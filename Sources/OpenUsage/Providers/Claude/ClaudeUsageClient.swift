import Foundation

extension ClaudeLogin {
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes
        ]
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: tokenURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: response.body).grant(now: now)
    }
}

/// The `/api/oauth/profile` payload. Carries the account/organization identity used for multi-account
/// verification plus the organization's *current* plan (`organization_type`, `rate_limit_tier`). The
/// stored login only has the plan Claude Code stamped at sign-in, so this is the source that reflects
/// an upgrade.
struct ClaudeAccountProfile: Decodable, Hashable, Sendable {
    struct Account: Decodable, Hashable, Sendable {
        var uuid: String
    }

    struct Organization: Decodable, Hashable, Sendable {
        var uuid: String
        var organizationType: String?
        var rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case organizationType = "organization_type"
            case rateLimitTier = "rate_limit_tier"
        }
    }

    var account: Account
    var organization: Organization?

    /// The sign-in's identity for spotting a login added twice (`AccountCredential.identity`): the
    /// account and the organization, since one person in two organizations has two sets of limits.
    var identity: String { Self.identity(accountUUID: account.uuid, organizationUUID: organization?.uuid) }

    static func identity(accountUUID: String, organizationUUID: String?) -> String {
        [accountUUID, organizationUUID].compactMap { $0 }.joined(separator: "/")
    }
}

struct ClaudeUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let resetGrantsURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    /// `GET /api/oauth/usage`, the plain read Claude Code makes for its own usage display.
    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await sendUsageRequest(url: Self.usageURL, accessToken: accessToken)
    }

    /// `GET /api/oauth/usage?cedar_ember=1&skip_spend=1`, the exact request Claude Code makes when it checks
    /// for a reset to offer. `cedar_ember=1` opts in to Anthropic's one-off usage-limit reset grants (the
    /// Rate Limit Resets row), which the plain read returns as `null`; `skip_spend=1` drops the spend
    /// figures this request doesn't need. Anthropic rate-limits this variant hard when it's polled, so the
    /// runtime asks at most once an hour. Anthropic also decides grant eligibility by client surface: a
    /// User-Agent it doesn't recognize as Claude Code comes back `eligible: false,
    /// ineligible_reason: "surface"` with no grants.
    func fetchResetGrants(accessToken: String) async throws -> HTTPResponse {
        try await sendUsageRequest(url: Self.resetGrantsURL, accessToken: accessToken)
    }

    private func sendUsageRequest(url: URL, accessToken: String) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(method: "GET", url: url, headers: Self.claudeCodeHeaders(accessToken), timeout: 10)
        )
    }

    /// `POST /api/organizations/{org}/reset_rate_limits`, the request Claude Code sends to spend one reset
    /// grant. `request_id` makes a retry idempotent: Anthropic answers a repeated id with `already_used`
    /// instead of spending a second reset.
    func claimResetGrant(
        accessToken: String, organizationUUID: String, grantID: String, requestID: String
    ) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember", "grant_id": grantID, "request_id": requestID
        ])
        return try await httpClient.send(HTTPRequest(
            method: "POST",
            url: Self.resetClaimURL(organizationUUID: organizationUUID),
            headers: Self.claudeCodeHeaders(accessToken),
            body: body,
            timeout: 25
        ))
    }

    static func resetClaimURL(organizationUUID: String) -> URL {
        usageURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("organizations")
            .appendingPathComponent(organizationUUID)
            .appendingPathComponent("reset_rate_limits")
    }

    private static func claudeCodeHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.294 (external, cli)"
        ]
    }

    /// `GET /api/oauth/profile`. Transport failures surface as `connectionFailed`; the status code is the
    /// caller's to triage.
    func fetchProfile(accessToken: String) async throws -> HTTPResponse {
        do {
            return try await httpClient.send(HTTPRequest(
                method: "GET",
                url: Self.profileURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "anthropic-beta": "oauth-2025-04-20"
                ],
                timeout: 10
            ))
        } catch {
            throw ProviderError.connectionFailed
        }
    }

    /// Decodes a 2xx profile body; a non-2xx status or an undecodable body throws the matching usage error.
    static func decodeProfile(_ response: HTTPResponse) throws -> ClaudeAccountProfile {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.failed(response)
        }
        guard let profile = try? JSONDecoder().decode(ClaudeAccountProfile.self, from: response.body) else {
            throw ProviderError.invalidResponse
        }
        return profile
    }
}
