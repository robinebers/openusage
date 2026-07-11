import Foundation

struct KiroUsageClient: Sendable {
    static let socialRefreshURL = URL(string: "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken")!
    static let oidcRefreshURL = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Fetch usage limits from the Q / CodeWhisperer API. The `profileArn` query parameter identifies
    /// the user's subscription; `origin=AI_EDITOR` and `resourceType=AGENTIC_REQUEST` match what the
    /// Kiro IDE sends. Returns the raw HTTP response for the mapper to parse.
    func fetchUsageLimits(accessToken: String, profileArn: String, region: String) async throws -> HTTPResponse {
        let baseURL = "https://q.\(region).amazonaws.com/getUsageLimits"
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "origin", value: "AI_EDITOR"),
            URLQueryItem(name: "profileArn", value: profileArn),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST"),
        ]
        guard let url = components.url else {
            throw KiroUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
            ],
            timeout: 15
        ))
    }

    /// Refresh a social-login token (Google/GitHub/Microsoft) via Kiro's desktop auth endpoint.
    /// Returns the new access token and (optionally) a new refresh token.
    func refreshSocialToken(refreshToken: String) async throws -> KiroRefreshedToken {
        let body: [String: Any] = ["refreshToken": refreshToken]
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.socialRefreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))

        guard (200..<300).contains(response.statusCode) else {
            throw KiroUsageError.requestFailed(response.statusCode)
        }

        guard let json = ProviderParse.jsonObject(response.body),
              let accessToken = (json["accessToken"] as? String)?.nilIfEmpty
        else {
            throw KiroUsageError.invalidResponse
        }

        let newRefreshToken = (json["refreshToken"] as? String)?.nilIfEmpty
        let expiresIn = ProviderParse.number(json["expiresIn"])
        let profileArn = (json["profileArn"] as? String)?.nilIfEmpty

        return KiroRefreshedToken(
            accessToken: accessToken,
            refreshToken: newRefreshToken ?? refreshToken,
            expiresIn: expiresIn,
            profileArn: profileArn
        )
    }

    /// Refresh an OIDC token via AWS SSO OIDC endpoint. Requires the client ID and secret from the
    /// device registration stored in the CLI database. AWS SSO OIDC expects form-encoded parameters
    /// with snake_case keys, not a JSON body.
    func refreshOIDCToken(refreshToken: String, clientId: String, clientSecret: String, region: String) async throws -> KiroRefreshedToken {
        let url = URL(string: "https://oidc.\(region).amazonaws.com/token")!
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken.urlFormEncoded)&client_id=\(clientId.urlFormEncoded)&client_secret=\(clientSecret.urlFormEncoded)"
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))

        guard (200..<300).contains(response.statusCode) else {
            throw KiroUsageError.requestFailed(response.statusCode)
        }

        guard let json = ProviderParse.jsonObject(response.body),
              let accessToken = coalesce(json["accessToken"], json["access_token"])?.nilIfEmpty
        else {
            throw KiroUsageError.invalidResponse
        }

        let newRefreshToken = coalesce(json["refreshToken"], json["refresh_token"]) ?? refreshToken
        let expiresIn = ProviderParse.number(json["expiresIn"]) ?? ProviderParse.number(json["expires_in"])

        return KiroRefreshedToken(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn,
            profileArn: nil
        )
    }

    private func coalesce(_ a: Any?, _ b: Any?) -> String? {
        if let s = a as? String { return s }
        if let s = b as? String { return s }
        return nil
    }
}

struct KiroRefreshedToken: Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Double?
    var profileArn: String?
}

enum KiroUsageError: Error, LocalizedError, Equatable, CategorizedError {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case tokenRefreshFailed
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .tokenRefreshFailed:
            return "Kiro session expired. Sign in to Kiro IDE or run kiro-cli login, then refresh."
        case .quotaUnavailable:
            return "Kiro usage data unavailable. Try again later."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .tokenRefreshFailed: .authExpired
        case .quotaUnavailable: .notAvailable
        }
    }
}
