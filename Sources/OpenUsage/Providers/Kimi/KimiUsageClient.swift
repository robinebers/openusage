import Foundation

struct KimiRefreshResponse: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var scope: String?
    var tokenType: String?
}

/// Calls the Kimi Code usage API and the OAuth token endpoint the Kimi Code CLI itself uses. The
/// usage endpoint accepts both a CLI OAuth access token and a console API key as the Bearer value.
struct KimiUsageClient: Sendable {
    /// The Kimi Code CLI's public OAuth client id — the token endpoint takes no client secret.
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "User-Agent": "OpenUsage"
            ],
            timeout: 15
        ))
    }

    func refreshToken(_ refreshToken: String) async throws -> KimiRefreshResponse {
        let body =
            "client_id=\(Self.clientID.urlFormEncoded)" +
            "&grant_type=refresh_token" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: Data(body.utf8),
            timeout: 15
        ))

        // A rejected refresh token means the CLI session is over — only a new `kimi` sign-in fixes it.
        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            throw KimiAuthError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw KimiUsageError.requestFailed(response.statusCode)
        }
        // A 2xx whose body carries no usable access token is treated as a dead session (re-login is
        // the right remedy), matching the Codex refresh handling.
        guard let bodyObject = ProviderParse.jsonObject(response.body),
              let accessToken = bodyObject["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw KimiAuthError.sessionExpired
        }

        return KimiRefreshResponse(
            accessToken: accessToken,
            refreshToken: bodyObject["refresh_token"] as? String,
            expiresIn: ProviderParse.number(bodyObject["expires_in"]),
            scope: bodyObject["scope"] as? String,
            tokenType: bodyObject["token_type"] as? String
        )
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not reach Kimi. Check your connection."
        case .invalidResponse:
            return "Kimi usage response was invalid. Try again later."
        case .requestFailed(let status):
            return "Kimi usage request failed (HTTP \(status)). Try again later."
        }
    }
}
