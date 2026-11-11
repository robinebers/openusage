import Foundation

extension OpenCodeLogin {
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let response = try await LoginHTTP.postForm(tokenURL, fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ], using: http)
        return try OAuthTokenResponse(renewal: response, kind: .opencodeGo).grant(now: now)
    }
}

struct OpenCodeUsageClient: Sendable {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// The Go subscription as OpenCode Console's own Go page reads it. It names the plan as `product`.
    static let goStatusURL = URL(string: "https://opencode.ai/console/api/go/status")!

    var http: any HTTPClient

    /// Takes either an API key or a Console sign-in's access token, with the workspace the sign-in chose,
    /// sent the way the OpenCode CLI sends it.
    func fetchUsage(token: String, orgID: String?) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json"]
        headers["x-opencode-org-id"] = orgID
        return try await LoginHTTP.get(Self.usageURL, bearerToken: token, using: http, headers: headers)
    }

    func fetchGoStatus(accessToken: String, orgID: String?) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json"]
        headers["x-org-id"] = orgID
        return try await LoginHTTP.get(Self.goStatusURL, bearerToken: accessToken, using: http, headers: headers)
    }
}
