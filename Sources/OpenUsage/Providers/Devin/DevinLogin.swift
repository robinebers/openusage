import Foundation

/// Devin accounts sign in the way the Devin CLI does: PKCE in the browser with a loopback callback, then a
/// code exchange that returns the session token the Devin API servers take as an API key. Devin accepts
/// only `http://127.0.0.1:<any port>/callback` as the redirect; it refuses `localhost` and other paths.
struct DevinLogin: ProviderLogin {
    static let authorizeURL = URL(string: "https://app.devin.ai/auth/cli/continue")!
    static let tokenURL = URL(string: "https://api.devin.ai/auth/cli/token")!
    static let sessionTokenPrefix = "devin-session-token$"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server = try await LoopbackCallbackServer.start(state: state, redirectHost: "127.0.0.1")
        defer { server.cancel() }
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        await prompt(.browser(components.url!, acceptsPastedCode: false))
        let code = try await withTaskCancellationHandler { try await server.waitForCode() } onCancel: { server.cancel() }

        let exchange = try await LoginHTTP.postJSON(Self.tokenURL, fields: ["code": code, "code_verifier": pkce.verifier], using: http)
        guard (200..<300).contains(exchange.statusCode) else {
            AppLog.error(LogTag.auth("devin"), "code exchange failed with HTTP \(exchange.statusCode)")
            throw LoginError.failed("Devin didn’t accept the sign-in. Click Try Again to sign in again.")
        }
        let token = try LoginHTTP.decode(CLITokenResponse.self, from: exchange).token
        guard !token.isEmpty else { throw LoginError.invalidResponse }
        var tokens = OAuthTokens(accessToken: token.hasPrefix(Self.sessionTokenPrefix) ? token : Self.sessionTokenPrefix + token)

        let status = try await DevinUsageClient(http: http).fetchUserStatus(tokens)
        guard (200..<300).contains(status.statusCode) else {
            AppLog.error(LogTag.auth("devin"), "user status read failed with HTTP \(status.statusCode) after sign-in")
            throw LoginError.failed("Devin signed you in but didn’t return your account. Click Try Again to sign in again.")
        }
        let user = try LoginHTTP.decode(UserStatusResponse.self, from: status).userStatus
        if let email = user.email {
            tokens.extras[OAuthTokens.identityKey] = user.teamId.map { "devin:\(email)/\($0)" } ?? "devin:\(email)"
        }
        return (user.email ?? "Devin Account", .oauth(tokens))
    }
}

private struct CLITokenResponse: Decodable {
    let token: String
}

private struct UserStatusResponse: Decodable {
    struct UserStatus: Decodable {
        let email: String?
        let teamId: String?
    }
    let userStatus: UserStatus
}
