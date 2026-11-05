import Foundation

struct CopilotLogin: ProviderLogin {
    static let clientID = String(data: Data(base64Encoded: "SXYxLmI1MDdhMDhjODdlY2ZlOTg=")!, encoding: .utf8)!
    /// The scope Copilot's own sign-in asks for, known to read `/copilot_internal/user`. GitHub's `/user`
    /// names the account with any token; whether the quota read works with no scope at all is unverified.
    static let scopes = "read:user"
    var domain = GitHubDomain.github
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        do {
            return try await signIn(prompt: prompt)
        } catch let error as URLError {
            guard case .enterprise(let host) = domain else { throw error }
            AppLog.warn(LogTag.auth("copilot"), "could not reach \(host): URLError \(error.code.rawValue)")
            throw ProviderError.unavailable("Couldn’t reach \(host). Check the address and your connection.")
        }
    }

    private func signIn(prompt: @Sendable (LoginPrompt) async -> Void) async throws -> (label: String, credential: AccountCredential) {
        let token = try await deviceAuthorization(
            provider: "GitHub",
            startURL: domain.webURL("/login/device/code"),
            tokenURL: domain.webURL("/login/oauth/access_token"),
            clientID: Self.clientID,
            scopes: Self.scopes,
            headers: ["User-Agent": "OpenUsage"],
            deniedMessage: "GitHub device sign-in was denied.",
            http: http,
            prompt: prompt
        )
        let profile = try await LoginHTTP.get(domain.apiURL("/user"), bearerToken: token.accessToken, using: http, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "OpenUsage",
            "X-GitHub-Api-Version": "2022-11-28"
        ])
        let user = try LoginHTTP.decode(GitHubUser.self, from: profile)
        let userID = user.id.map(String.init) ?? user.login
        var identity = "github:\(userID)"
        if case .enterprise(let host) = domain {
            try await requireSeat(token: token.accessToken, login: user.login)
            // The same user id on two domains is two accounts.
            identity = "github:\(host):\(userID)"
        }
        return (user.login, .oauth(OAuthTokens(accessToken: token.accessToken, extras: [OAuthTokens.identityKey: identity])))
    }

    /// An enterprise sign-in reads usage once, so an account without a Copilot seat is never added.
    private func requireSeat(token: String, login: String) async throws {
        let usage = try await CopilotUsageClient(http: http).fetchUsage(token: token, domain: domain)
        guard !(200..<300).contains(usage.statusCode) else { return }
        AppLog.warn(LogTag.auth("copilot"), "seat check on \(domain.host) failed with HTTP \(usage.statusCode)")
        if ProviderError.isAuthFailure(usage) || usage.statusCode == 404 {
            throw ProviderError.unavailable("\(login) has no Copilot seat on \(domain.host). Ask your GitHub admin for one, then try again.")
        }
        throw ProviderError.failed(usage)
    }
}

struct GrokLogin: ProviderLogin {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let scopes = "openid email offline_access grok-cli:access"
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
        let claims = ProviderParse.jwtPayloadData(token.accessToken).flatMap { try? JSONDecoder().decode(GrokIDClaims.self, from: $0) }
        return (claims?.email ?? "Grok Account", .oauth(token.tokens(extras: (claims?.sub ?? claims?.email).map { [OAuthTokens.identityKey: $0] } ?? [:])))
    }
}

/// Muse Code's device sign-in, under the Muse CLI's own public client: Meta registers no other clients.
/// It sends no scope: the usage read needs none, and the device endpoint refuses `openid`. The sign-in
/// returns a `dca:` token with no refresh token, and the account takes the email Muse reports for it.
struct MuseLogin: ProviderLogin {
    static let clientID = "1031625952748946"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let token = try await deviceAuthorization(
            provider: "Meta",
            startURL: URL(string: "https://auth.meta.com/oidc/device/authorization/")!,
            tokenURL: URL(string: "https://auth.meta.com/oidc/device/token/")!,
            clientID: Self.clientID,
            scopes: nil,
            deniedMessage: "Meta device sign-in was denied.",
            http: http,
            prompt: prompt
        )
        let email = try await MuseUsageClient(http: http).account(token: token.accessToken).email?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        return (email ?? ProviderKind.muse.displayName, .oauth(OAuthTokens(
            accessToken: token.accessToken,
            extras: email.map { [OAuthTokens.identityKey: "muse:\($0)"] } ?? [:]
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
        return (await profileName(accessToken: token.accessToken) ?? "Cursor Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: ProviderParse.jwtExpiry(token.accessToken),
            extras: userID.map { [OAuthTokens.identityKey: "cursor:\($0)"] } ?? [:]
        )))
    }

    private func profileName(accessToken: String) async -> String? {
        do {
            guard let response = try await CursorUsageClient(http: http).fetchProfile(accessToken: accessToken) else {
                throw LoginError.invalidResponse
            }
            let profile = try LoginHTTP.decode(CursorProfile.self, from: response)
            return [profile.email, profile.name].compactMap { $0 }.first { !$0.isEmpty }
        } catch {
            AppLog.warn(LogTag.auth("cursor"), "profile read failed, naming the account Cursor Account: \(error.localizedDescription)")
            return nil
        }
    }
}

struct APIKeyLogin: ProviderLogin {
    let kind: ProviderKind
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        var iterator = pastedCode.makeAsyncIterator()
        guard let value = await iterator.next() else { throw LoginError.cancelled }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LoginError.invalidCode }
        let account = Account(kind: kind, label: kind.displayName)
        let runtime = await AccountProviderRuntime(account: account, vault: KeychainCredentialVault(), http: http)
        do {
            try await runtime.readSnapshot(using: .apiKey(key))
        } catch ProviderError.keyRejected(let message) {
            throw ProviderError.unavailable(message)
        }
        guard kind == .ollama else { return (kind.displayName, .apiKey(key)) }
        let accountBody = await MainActor.run { runtime.planBodyRead.value }
        guard let email = accountBody.flatMap(OllamaUsageMapper.email(from:)) else {
            AppLog.warn(LogTag.auth("ollama"), "account read reported no email, naming the account Ollama")
            return (kind.displayName, .apiKey(key))
        }
        return (email, .apiKey(key))
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
    static func login(for kind: ProviderKind, method: ProviderAuthMethod, organization: String, domain: GitHubDomain) -> any ProviderLogin {
        if method == .organizationToken { return CopilotOrganizationLogin(organization: organization) }
        return switch kind {
        case .claude: ClaudeLogin()
        case .codex: CodexLogin()
        case .cursor: CursorLogin()
        case .antigravity: AntigravityLogin()
        case .copilot: CopilotLogin(domain: domain)
        case .devin: DevinLogin()
        case .grok: GrokLogin()
        case .muse: MuseLogin()
        case .ollama, .opencodeGo, .openrouter, .zai: APIKeyLogin(kind: kind)
        }
    }
}

private func deviceAuthorization(
    provider: String,
    startURL: URL,
    tokenURL: URL,
    clientID: String,
    scopes: String?,
    headers: [String: String] = [:],
    deniedMessage: String,
    http: any HTTPClient,
    prompt: @Sendable (LoginPrompt) async -> Void
) async throws -> OAuthTokenResponse {
    var fields = ["client_id": clientID]
    fields["scope"] = scopes
    let start = try await LoginHTTP.postForm(startURL, fields: fields, using: http, headers: headers)
    let device = try LoginHTTP.decode(DeviceCode.self, from: start)
    let candidates = [device.verificationURIComplete, device.verificationURI].compactMap { $0.flatMap(URL.init(string:)) }
    guard let verificationURL = candidates.first(where: { $0.scheme == "https" && $0.host?.isEmpty == false }) else {
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
        return switch ProviderParse.jsonObject(response.body)?["error"] as? String {
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
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
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

private struct CursorProfile: Decodable {
    let email: String?
    let name: String?
}

private struct GrokIDClaims: Decodable {
    let sub: String?
    let email: String?
}
