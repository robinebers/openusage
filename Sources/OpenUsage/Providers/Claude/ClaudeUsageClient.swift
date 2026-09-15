import Foundation

struct ClaudeRefreshResponse: Decodable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

/// The `/api/oauth/profile` payload. Carries the account/organization identity used for multi-account
/// verification plus the organization's *current* plan (`organization_type`, `rate_limit_tier`). The
/// stored login only has the plan Claude Code stamped at sign-in, so this is the source that reflects
/// an upgrade (issue #1258).
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
}

enum ClaudeAccountVerification: Sendable {
    /// The token belongs to the expected account and organization. Carries the decoded profile so the
    /// caller can read the live plan from it without a second request.
    case verified(ClaudeAccountProfile)
    /// Non-2xx from the profile endpoint, handed back unchanged so the caller can treat it like a failed
    /// usage response (401 → token refresh, 429 → cooldown, anything else → request failure).
    case failed(HTTPResponse)
}

struct ClaudeUsageClient: Sendable {
    private static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func refreshToken(_ refreshToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "scope": Self.scopes
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: config.refreshURL,
                headers: ["Content-Type": "application/json"],
                body: bodyData,
                timeout: 15
            )
        )
    }

    func fetchUsage(accessToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: config.usageURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: 10
            )
        )
    }

    /// `GET /api/oauth/profile`. Transport failures surface as `connectionFailed`; the status code is the
    /// caller's to triage.
    func fetchProfile(accessToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        do {
            return try await httpClient.send(HTTPRequest(
                method: "GET",
                url: config.usageURL.deletingLastPathComponent().appendingPathComponent("profile"),
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "anthropic-beta": "oauth-2025-04-20"
                ],
                timeout: 10
            ))
        } catch {
            throw ClaudeUsageError.connectionFailed
        }
    }

    /// Decodes a 2xx profile body; a non-2xx status or an undecodable body throws the matching usage error.
    static func decodeProfile(_ response: HTTPResponse) throws -> ClaudeAccountProfile {
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard let profile = try? JSONDecoder().decode(ClaudeAccountProfile.self, from: response.body) else {
            throw ClaudeUsageError.invalidResponse
        }
        return profile
    }

    func verifyAccount(
        accessToken: String,
        expectedIdentityKey: String,
        config: ClaudeOAuthConfig
    ) async throws -> ClaudeAccountVerification {
        let expected = expectedIdentityKey.split(separator: "|", omittingEmptySubsequences: false)
        guard expected.count == 2 else { throw ClaudeAuthError.sessionExpired }

        let response = try await fetchProfile(accessToken: accessToken, config: config)
        guard (200..<300).contains(response.statusCode) else { return .failed(response) }
        let profile = try Self.decodeProfile(response)
        guard profile.account.uuid.caseInsensitiveCompare(String(expected[0])) == .orderedSame,
              profile.organization?.uuid.caseInsensitiveCompare(String(expected[1])) == .orderedSame
        else {
            AppLog.warn(LogTag.auth("claude"), "Claude credential does not match its account or organization")
            throw ClaudeAuthError.sessionExpired
        }
        return .verified(profile)
    }
}
