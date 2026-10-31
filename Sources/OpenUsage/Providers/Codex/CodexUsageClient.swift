import Foundation

extension CodexLogin {
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let body =
            "grant_type=refresh_token" +
            "&client_id=\(clientID.urlFormEncoded)" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
        let token = try OAuthTokenResponse(renewal: response, kind: .codex)
        return OAuthGrant(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: ProviderParse.jwtExpiry(token.accessToken)
        )
    }
}

struct CodexUsageClient: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeResetCreditURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    static let reportsURL = URL(string: "https://chatgpt.com/backend-api/wham/")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: Self.usageHeaders(accessToken: accessToken, accountID: accountID),
            timeout: 10
        ))
    }

    /// One of the daily usage reports the Codex client's Analytics view reads, such as
    /// `usage/credit-usage-events`, at `path` under `wham/`.
    func fetchReport(_ path: String, query: [URLQueryItem], accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var url = Self.reportsURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return try await http.send(HTTPRequest(
            method: "GET", url: url, headers: Self.usageHeaders(accessToken: accessToken, accountID: accountID), timeout: 15
        ))
    }

    /// On-demand rate-limit reset credits, including each credit's expiry. A separate endpoint from
    /// `usage`, whose `rate_limit_reset_credits` carries only the count. The extra headers mirror the Codex
    /// desktop client, which the endpoint expects.
    func fetchResetCredits(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.resetCreditsURL,
            headers: Self.resetCreditHeaders(accessToken: accessToken, accountID: accountID),
            timeout: 10
        ))
    }

    func consumeResetCredit(
        accessToken: String,
        accountID: String?,
        creditID: String,
        redeemRequestID: String
    ) async throws -> HTTPResponse {
        var headers = Self.resetCreditHeaders(accessToken: accessToken, accountID: accountID)
        headers["Content-Type"] = "application/json"
        let payload = ["redeem_request_id": redeemRequestID, "credit_id": creditID]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.consumeResetCreditURL,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            timeout: 15
        ))
    }

    private static func resetCreditHeaders(accessToken: String, accountID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

    private static func usageHeaders(accessToken: String, accountID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

}
