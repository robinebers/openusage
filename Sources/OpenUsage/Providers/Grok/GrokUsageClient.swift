import Foundation

extension GrokLogin {
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
        guard (200..<300).contains(response.statusCode),
              let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: response.body)
        else { throw ProviderError.failed(response) }
        return token.grant(now: now)
    }
}

struct GrokUsageClient: Sendable {
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let tokenAuthHeader = "xai-grok-cli"

    /// The weekly shared-pool data: the billing endpoint with `?format=credits`, which returns
    /// the `GetGrokCreditsConfig` message as JSON.
    static let creditsConfigURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchCreditsConfig(accessToken: String) async throws -> HTTPResponse {
        try await httpClient.send(HTTPRequest(
            method: "GET",
            url: Self.creditsConfigURL,
            headers: authHeaders(accessToken: accessToken),
            timeout: 10
        ))
    }

    func fetchSettings(accessToken: String) async throws -> HTTPResponse {
        try await httpClient.send(HTTPRequest(
            method: "GET",
            url: Self.settingsURL,
            headers: authHeaders(accessToken: accessToken),
            timeout: 10
        ))
    }

    private func authHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "X-XAI-Token-Auth": Self.tokenAuthHeader,
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
    }
}
