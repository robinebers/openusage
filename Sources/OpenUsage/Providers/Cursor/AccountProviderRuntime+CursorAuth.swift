import Foundation

extension AccountProviderRuntime {
    /// Cursor's access token is a 60-day JWT that is also its refresh token, so the sign-in dies at that
    /// JWT's `exp`. Refreshing a week early keeps the account alive when the Mac is off around expiry.
    static let cursorRefreshLead: TimeInterval = 7 * 86_400

    /// The account's Cursor tokens. They are refreshed and saved back once they're within
    /// `cursorRefreshLead` of expiring. A credential saved without an expiry gets one from the JWT
    /// `exp` here. If an early refresh fails, the token that is still valid is kept, and the next
    /// refresh tries again.
    func cursorTokens(_ credential: AccountCredential) async throws -> OAuthTokens {
        guard case .oauth(var tokens) = credential else { throw ProviderError.invalidResponse }
        let hadExpiry = tokens.expiresAt != nil
        tokens.expiresAt = tokens.expiresAt ?? ProviderParse.jwtExpiry(tokens.accessToken)
        guard let expiresAt = tokens.expiresAt else { return tokens }
        if expiresAt.addingTimeInterval(-Self.cursorRefreshLead) <= now() {
            do {
                return try await refreshCursorTokens(tokens)
            } catch let error where expiresAt > now() {
                AppLog.warn(
                    LogTag.plugin("cursor"),
                    "\(account.cardID) early token refresh failed; keeping the current token: \(error.localizedDescription)"
                )
            }
        }
        if !hadExpiry { try await replaceCredential(.oauth(tokens)) }
        return tokens
    }

    /// Trades the refresh token at `/oauth/token` for a new 60-day access token and saves it. Cursor
    /// answers with `access_token` and no `refresh_token`. The new JWT then works as the next refresh
    /// token, the same way the login poll pairs them. `shouldLogout` means Cursor ended the session.
    func refreshCursorTokens(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw ProviderError.signInExpired(.cursor) }
        let response = try await CursorUsageClient(http: http).refreshToken(refreshToken)
        let body = ProviderParse.jsonObject(response.body)
        if body?["shouldLogout"] as? Bool == true { throw ProviderError.signInExpired(.cursor) }
        guard (200..<300).contains(response.statusCode),
              let accessToken = body?["access_token"] as? String,
              !accessToken.isEmpty
        else { throw ProviderError.signInExpired(.cursor) }
        var refreshed = tokens
        refreshed.accessToken = accessToken
        refreshed.refreshToken = body?["refresh_token"] as? String ?? accessToken
        refreshed.expiresAt = ProviderParse.jwtExpiry(accessToken)
        try await replaceCredential(.oauth(refreshed))
        return refreshed
    }
}
