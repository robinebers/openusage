import Foundation

struct CopilotLogin: ProviderLogin {
    static let clientID = String(data: Data(base64Encoded: "SXYxLmI1MDdhMDhjODdlY2ZlOTg=")!, encoding: .utf8)!
    /// The scope Copilot's own sign-in asks for, known to read `/copilot_internal/user`. GitHub's `/user`
    /// names the account with any token; whether the quota read works with no scope at all is unverified.
    static let scopes = "read:user"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let token = try await deviceAuthorization(
            provider: "GitHub",
            startURL: URL(string: "https://github.com/login/device/code")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            clientID: Self.clientID,
            scopes: Self.scopes,
            headers: ["User-Agent": "OpenUsage"],
            deniedMessage: "GitHub device sign-in was denied.",
            http: http,
            prompt: prompt
        )
        let profileURL = URL(string: "https://api.github.com/user")!
        let profile = try await LoginHTTP.get(profileURL, bearerToken: token.accessToken, using: http, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "OpenUsage",
            "X-GitHub-Api-Version": "2022-11-28"
        ])
        let user = try LoginHTTP.decode(GitHubUser.self, from: profile)
        return (user.login, .oauth(OAuthTokens(
            accessToken: token.accessToken,
            extras: [OAuthTokens.identityKey: user.id.map { "github:\($0)" } ?? "github:\(user.login)"]
        )))
    }
}

struct GrokLogin: ProviderLogin {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let scopes = "openid profile email offline_access grok-cli:access api:access"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let token = try await deviceAuthorization(
            provider: "xAI",
            startURL: URL(string: "https://auth.x.ai/oauth2/device/code")!,
            tokenURL: Self.tokenURL,
            clientID: Self.clientID,
            scopes: Self.scopes,
            deniedMessage: "xAI device sign-in failed.",
            http: http,
            prompt: prompt
        )
        let claims = token.accessToken.jwtPayload(as: GrokIDClaims.self)
        return (claims?.email ?? "Grok Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            extras: (claims?.sub ?? claims?.email).map { [OAuthTokens.identityKey: $0] } ?? [:]
        )))
    }
}

struct CursorLogin: ProviderLogin {
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let pkce = PKCE.generate()
        let uuid = UUID().uuidString
        var components = URLComponents(string: "https://cursor.com/loginDeepControl")!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: pkce.challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli")
        ]
        guard let authorizeURL = components.url else { throw LoginError.invalidResponse }
        await prompt(.browser(authorizeURL, acceptsPastedCode: false))
        let token: CursorTokenResponse = try await DeviceCodePoller.poll(interval: 2, expiresIn: 300) { [http] in
            var poll = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
            poll.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: pkce.verifier)
            ]
            guard let url = poll.url else { return .failed("Cursor sign-in URL was invalid.") }
            let response = try await LoginHTTP.get(url, using: http)
            if (200..<300).contains(response.statusCode),
               let token = try? LoginHTTP.decode(CursorTokenResponse.self, from: response),
               !token.accessToken.isEmpty, !token.refreshToken.isEmpty {
                return .complete(token)
            }
            if response.statusCode == 404 || response.statusCode == 202 { return .pending }
            return .failed("Cursor sign-in failed.")
        }
        let userID = CursorUsageClient.session(from: token.accessToken)?.userID
        return ("Cursor Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: ProviderParse.jwtExpiry(token.accessToken),
            extras: userID.map { [OAuthTokens.identityKey: "cursor:\($0)"] } ?? [:]
        )))
    }
}

struct APIKeyLogin: ProviderLogin {
    let kind: ProviderKind

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        var iterator = pastedCode.makeAsyncIterator()
        guard let value = await iterator.next() else { throw LoginError.cancelled }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LoginError.invalidCode }
        return (kind.displayName, .apiKey(key))
    }
}

/// Adds an organization's Copilot billing as its own account, checked with one read of the report.
struct CopilotOrganizationLogin: ProviderLogin {
    let organization: String
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        var iterator = pastedCode.makeAsyncIterator()
        guard let value = await iterator.next() else { throw LoginError.cancelled }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw LoginError.invalidCode }
        do {
            _ = try await CopilotUsageClient(http: http).organizationUsage(organization, token: token)
        } catch ProviderError.keyRejected(let message) {
            throw ProviderError.unavailable(message)
        }
        return (organization, .apiKey(token))
    }
}

enum ProviderLoginCatalog {
    static func login(for kind: ProviderKind, method: ProviderAuthMethod, organization: String) -> any ProviderLogin {
        if method == .organizationToken { return CopilotOrganizationLogin(organization: organization) }
        return switch kind {
        case .claude: ClaudeLogin()
        case .codex: CodexLogin()
        case .cursor: CursorLogin()
        case .antigravity: AntigravityLogin()
        case .copilot: CopilotLogin()
        case .devin: DevinLogin()
        case .grok: GrokLogin()
        case .ollama, .opencodeGo, .openrouter, .zai: APIKeyLogin(kind: kind)
        }
    }
}

private func deviceAuthorization(
    provider: String,
    startURL: URL,
    tokenURL: URL,
    clientID: String,
    scopes: String,
    headers: [String: String] = [:],
    deniedMessage: String,
    http: any HTTPClient,
    prompt: @Sendable (LoginPrompt) async -> Void
) async throws -> OAuthTokenResponse {
    let start = try await LoginHTTP.postForm(startURL, fields: ["client_id": clientID, "scope": scopes], using: http, headers: headers)
    let device = try LoginHTTP.decode(DeviceCode.self, from: start)
    guard let verificationURL = URL(string: device.verificationURI), verificationURL.scheme == "https" else {
        throw LoginError.invalidResponse
    }
    await prompt(.deviceCode(userCode: device.userCode, verificationURL: verificationURL))
    return try await DeviceCodePoller.poll(interval: device.interval ?? 5, expiresIn: TimeInterval(device.expiresIn)) {
        let response = try await LoginHTTP.postForm(tokenURL, fields: [
            "client_id": clientID,
            "device_code": device.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ], using: http, headers: headers)
        if let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: response.body) {
            return .complete(token)
        }
        return switch LoginHTTP.jsonObject(response)["error"] {
        case "authorization_pending": .pending
        case "slow_down": .slowDown
        case "expired_token": .failed("\(provider) device sign-in expired.")
        case "access_denied": .failed(deniedMessage)
        default: .failed("\(provider) device sign-in failed.")
        }
    }
}

private struct DeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GitHubUser: Decodable {
    let id: Int?
    let login: String
}

private struct CursorTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
}

private struct GrokIDClaims: Decodable {
    let sub: String?
    let email: String?
}
