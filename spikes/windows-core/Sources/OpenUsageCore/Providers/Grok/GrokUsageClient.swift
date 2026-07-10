import Foundation

struct GrokRefreshResponse: Decodable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

enum GrokUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Grok billing request failed. Check your connection."
        case .invalidResponse:
            return "Grok billing response changed."
        case .requestFailed(let statusCode):
            return "Grok billing request failed (HTTP \(statusCode)). Try again later."
        }
    }
}

struct GrokUsageClient: Sendable {
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let tokenAuthHeader = "xai-grok-cli"

    /// The weekly shared-pool data: the same billing endpoint with `?format=credits`, which returns
    /// the `GetGrokCreditsConfig` message as JSON. This is exactly what the Grok CLI itself calls
    /// (its `billing.rs` appends `/billing?format=credits` to the same proxy base URL), so it shares
    /// the CLI's stability guarantees, auth headers, and token-refresh path.
    static let creditsConfigURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func refreshToken(_ refreshToken: String, clientID: String) async throws -> HTTPResponse {
        let body =
            "grant_type=refresh_token" +
            "&client_id=\(clientID.urlFormEncoded)" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        return try await httpClient.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
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

    func decodeRefreshResponse(_ response: HTTPResponse) -> GrokRefreshResponse? {
        try? JSONDecoder().decode(GrokRefreshResponse.self, from: response.body)
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

