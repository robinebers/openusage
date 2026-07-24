import Foundation

struct KimiRefreshResponse: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var scope: String?
    var tokenType: String?
}

struct KimiUsageClient: Sendable {
    /// The Kimi Code CLI's own OAuth client. The refresh grant is bound to it, so it has to be reused —
    /// the same arrangement as the Codex, Claude, and Cursor providers, which refresh with their CLI's
    /// client id.
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let defaultBaseURL = "https://api.kimi.com/coding/v1"
    static let defaultOAuthHost = "https://auth.kimi.com"

    var http: any HTTPClient
    var environment: EnvironmentReading

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.http = http
        self.environment = environment
    }

    /// Mirrors the CLI's own endpoint resolution, so a user pointed at a staging or enterprise deployment
    /// keeps working instead of having OpenUsage query the wrong host.
    func baseURL() -> String {
        override("KIMI_CODE_BASE_URL") ?? Self.defaultBaseURL
    }

    func oauthHost() -> String {
        override("KIMI_CODE_OAUTH_HOST") ?? override("KIMI_OAUTH_HOST") ?? Self.defaultOAuthHost
    }

    /// The quota endpoint behind the CLI's `/usage` command. Returns the raw response so the provider can
    /// route 401/403 through `ProviderAuthRetry` before the mapper sees a body.
    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        guard let url = URL(string: "\(baseURL())/usages") else {
            throw KimiUsageError.invalidResponse
        }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ],
            timeout: 10
        ))
    }

    func refreshToken(_ refreshToken: String) async throws -> KimiRefreshResponse {
        guard let url = URL(string: "\(oauthHost())/api/oauth/token") else {
            throw KimiAuthError.invalidCredentials
        }
        let body =
            "client_id=\(Self.clientID.urlFormEncoded)" +
            "&grant_type=refresh_token" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))

        // The token endpoint rejects a dead refresh token with 401/403, and reports a bad grant as a 400
        // carrying an OAuth error code. A 400 without a recognized code is often a proxy/WAF page, so it's
        // reported as an HTTP failure rather than as an expiry the user can't fix by logging in again.
        if response.statusCode == 401 || response.statusCode == 403 {
            throw KimiAuthError.sessionExpired
        }
        if response.statusCode == 400 {
            let errorCode = ProviderParse.jsonObject(response.body)?["error"] as? String
            if errorCode == "invalid_grant" {
                throw KimiAuthError.sessionExpired
            }
            throw KimiUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw KimiUsageError.requestFailed(response.statusCode)
        }
        guard let payload = ProviderParse.jsonObject(response.body),
              let accessToken = (payload["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            // A 2xx that carries no usable token is a dead session; re-login is the right remedy.
            throw KimiAuthError.tokenExpired
        }

        return KimiRefreshResponse(
            accessToken: accessToken,
            refreshToken: payload["refresh_token"] as? String,
            expiresIn: ProviderParse.number(payload["expires_in"]),
            scope: payload["scope"] as? String,
            tokenType: payload["token_type"] as? String
        )
    }

    private func override(_ name: String) -> String? {
        environment.value(for: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty?
            .trimmingTrailingSlashes
            .nilIfEmpty
    }
}
