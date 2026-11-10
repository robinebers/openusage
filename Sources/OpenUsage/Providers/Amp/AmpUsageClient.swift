import Foundation

extension AmpLogin {
    /// WorkOS rotates the refresh token on every renewal and reports no `expires_in`; the access token's own
    /// `exp` says when it lapses, five minutes after it was granted.
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let response = try await LoginHTTP.postJSON(authenticateURL, fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ], using: http)
        let token = try OAuthTokenResponse(renewal: response, kind: .amp)
        return OAuthGrant(
            accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiresAt: ProviderParse.jwtExpiry(token.accessToken)
        )
    }
}

/// Amp reports usage only as the text `amp usage` prints, through its internal JSON-RPC API.
struct AmpUsageClient: Sendable {
    static let balanceURL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!

    var http: any HTTPClient

    func fetchBalance(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: Self.balanceURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            body: Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8),
            timeout: 15
        ))
    }
}
