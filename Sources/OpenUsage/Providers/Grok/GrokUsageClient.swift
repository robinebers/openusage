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
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let tokenAuthHeader = "xai-grok-cli"

    /// The weekly shared-pool data lives behind a gRPC-web RPC on grok.com (the website's transport;
    /// the CLI reaches the same backend over a WebSocket gateway we don't speak). Protobuf only —
    /// JSON codecs are rejected. Cloudflare fronts it and 403s unrecognized User-Agents; the
    /// standard `User-Agent: OpenUsage` header passes.
    static let creditsConfigURL = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

    /// The request message: protobuf field 1 varint = 1, captured from the website. An empty message
    /// is rejected (grpc-status 13 "Missing request message") and the field's semantics are unknown —
    /// treat these exact bytes as part of the protocol and keep them pinned by tests.
    static let creditsConfigRequestMessage = Data([0x08, 0x01])

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

    func fetchBilling(accessToken: String) async throws -> HTTPResponse {
        try await httpClient.send(HTTPRequest(
            method: "GET",
            url: Self.billingURL,
            headers: authHeaders(accessToken: accessToken),
            timeout: 10
        ))
    }

    func fetchCreditsConfig(accessToken: String) async throws -> HTTPResponse {
        var headers = authHeaders(accessToken: accessToken)
        headers["Accept"] = "application/grpc-web+proto"
        headers["Content-Type"] = "application/grpc-web+proto"
        headers["X-Grpc-Web"] = "1"
        return try await httpClient.send(HTTPRequest(
            method: "POST",
            url: Self.creditsConfigURL,
            headers: headers,
            body: GRPCWebCodec.frame(Self.creditsConfigRequestMessage),
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

