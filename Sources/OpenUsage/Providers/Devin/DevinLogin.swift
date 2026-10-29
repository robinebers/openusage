import Foundation

/// Devin accounts sign in through the token page that Windsurf's editor plugins use.
struct DevinLogin: ProviderLogin {
    static let tokenPageURL = URL(string: "https://windsurf.com/profile")!
    static let registerURL = URL(string: "https://api.codeium.com/register_user/")!
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        await prompt(.browserToken(Self.tokenPage(state: UUID().uuidString)))
        var iterator = pastedCode.makeAsyncIterator()
        guard let value = await iterator.next() else { throw LoginError.cancelled }
        let pasted = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else { throw LoginError.invalidCode }
        var tokens = try await registeredKey(token: pasted) ?? OAuthTokens(accessToken: pasted)
        let status = try await DevinUsageClient(http: http).fetchUserStatus(tokens)
        if ProviderError.isAuthFailure(status) {
            throw LoginError.failed("Windsurf rejected that token. A token works for 5 minutes, so click Try Again to get a new one.")
        }
        let user = try LoginHTTP.decode(UserStatusResponse.self, from: status).userStatus
        if let email = user.email {
            tokens.extras[OAuthTokens.identityKey] = user.teamId.map { "devin:\(email)/\($0)" } ?? "devin:\(email)"
        }
        return (user.email ?? "Devin Account", .oauth(tokens))
    }

    private static func tokenPage(state: String) -> URL {
        var components = URLComponents(url: tokenPageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "redirect_uri", value: "show-auth-token"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "redirect_parameters_type", value: "query")
        ]
        return components.url!
    }

    /// RegisterUser refuses anything but a token from the page, so after a refusal the pasted value is
    /// tried as an API key.
    private func registeredKey(token: String) async throws -> OAuthTokens? {
        let response = try await LoginHTTP.postJSON(Self.registerURL, fields: ["firebase_id_token": token], using: http)
        if ProviderError.isAuthFailure(response) { return nil }
        let registered = try LoginHTTP.decode(RegisterUserResponse.self, from: response)
        guard !registered.apiKey.isEmpty else { throw LoginError.invalidResponse }
        var tokens = OAuthTokens(accessToken: registered.apiKey)
        if let server = registered.apiServerURL, !server.isEmpty {
            guard let url = URL(string: server), url.scheme == "https", url.host() != nil else { throw LoginError.invalidResponse }
            tokens.extras[DevinUsageClient.apiServerURLKey] = server
        }
        return tokens
    }
}

private struct RegisterUserResponse: Decodable {
    let apiKey: String
    let apiServerURL: String?
    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case apiServerURL = "api_server_url"
    }
}

private struct UserStatusResponse: Decodable {
    struct UserStatus: Decodable {
        let email: String?
        let teamId: String?
    }
    let userStatus: UserStatus
}
