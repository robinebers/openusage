import Foundation

struct ClaudeLogin: ProviderLogin {
    static let clientID = String(data: Data(base64Encoded: "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")!, encoding: .utf8)!
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// `/api/oauth/usage` and `/api/oauth/profile` gate on `user:profile` and nothing else (Anthropic answers
    /// a token without it with "OAuth token does not meet scope requirement user:profile"). The refresh
    /// grant sends the same string, so a refreshed token never carries more than the sign-in granted.
    static let scopes = "user:profile"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server = try await LoopbackCallbackServer.start(state: state)
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: Self.clientID, scopes: Self.scopes, state: state, pkce: pkce, server: server,
            extraQuery: [URLQueryItem(name: "code", value: "true")],
            prompt: prompt, pastedCode: pastedCode
        )
        let response = try await LoginHTTP.postJSON(Self.tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "state": state,
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        var info: ClaudeProfileResponse?
        if let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile"),
           let profile = try? await LoginHTTP.get(profileURL, bearerToken: token.accessToken, using: http) {
            info = try? LoginHTTP.decode(ClaudeProfileResponse.self, from: profile)
        }
        let identity = (info?.account?.uuid).map {
            ClaudeAccountProfile.identity(accountUUID: $0, organizationUUID: info?.organization?.uuid)
        }
        return (info?.account?.email ?? info?.email ?? "Claude Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            extras: identity.map { [OAuthTokens.identityKey: $0] } ?? [:]
        )))
    }
}

struct CodexLogin: ProviderLogin {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let scopes = "openid profile email offline_access"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        guard let server = try? await LoopbackCallbackServer.start(state: state, port: 1455, path: "/auth/callback") else {
            return try await deviceLogin(prompt: prompt)
        }
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: Self.clientID, scopes: Self.scopes, state: state, pkce: pkce, server: server,
            extraQuery: [
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "pi")
            ],
            prompt: prompt, pastedCode: pastedCode
        )
        return try await exchange(code: code, verifier: pkce.verifier, redirectURI: server.redirectURI)
    }

    private func deviceLogin(prompt: @Sendable (LoginPrompt) async -> Void) async throws -> (label: String, credential: AccountCredential) {
        let deviceURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        let start = try await LoginHTTP.postJSON(deviceURL, fields: ["client_id": Self.clientID], using: http)
        let device = try LoginHTTP.decode(CodexDeviceStart.self, from: start)
        let verifyURL = URL(string: "https://auth.openai.com/codex/device")!
        await prompt(.deviceCode(userCode: device.userCode, verificationURL: verifyURL))
        let deviceToken: CodexDeviceToken = try await DeviceCodePoller.poll(interval: device.interval, expiresIn: 900) { [http] in
            let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
            let response = try await LoginHTTP.postJSON(url, fields: [
                "device_auth_id": device.deviceAuthID,
                "user_code": device.userCode
            ], using: http)
            if (200..<300).contains(response.statusCode) {
                return .complete(try LoginHTTP.decode(CodexDeviceToken.self, from: response))
            }
            let error = LoginHTTP.jsonObject(response)["error"] ?? ""
            if response.statusCode == 403 || response.statusCode == 404 || error == "deviceauth_authorization_pending" {
                return .pending
            }
            if error == "slow_down" { return .slowDown }
            return .failed(error == "expired_token" ? "Device sign-in expired." : "Device sign-in failed.")
        }
        return try await exchange(
            code: deviceToken.authorizationCode,
            verifier: deviceToken.codeVerifier,
            redirectURI: "https://auth.openai.com/deviceauth/callback"
        )
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> (label: String, credential: AccountCredential) {
        let response = try await LoginHTTP.postForm(Self.tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        let accessClaims = token.accessToken.jwtPayload(as: CodexAccessClaims.self)
        let idClaims = token.idToken?.jwtPayload(as: CodexIDClaims.self)
        let accountID = accessClaims?.auth?.chatgptAccountID
        var extras: [String: String] = [:]
        extras["chatgpt_account_id"] = accountID
        if let accountID, let email = idClaims?.email { extras[OAuthTokens.identityKey] = "\(accountID)/\(email)" }
        return (idClaims?.email ?? "ChatGPT Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            extras: extras
        )))
    }
}

struct AntigravityLogin: ProviderLogin {
    /// Google OAuth "installed application" client credentials, the pair the Antigravity app ships with.
    /// Google does not treat an installed-app client's "secret" as confidential (it is in every copy of
    /// the client), and the refresh-token grant requires it, so committing it is an accepted trade-off.
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    /// Cloud Code (`loadCodeAssist`, `retrieveUserQuotaSummary`) is a Google Cloud API and takes
    /// `cloud-platform`; `userinfo.email` names the account. The Antigravity app also asks for
    /// `userinfo.profile`, `cclog`, and `experimentsandconfigs`, which the quota reads never use.
    static let scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server = try await LoopbackCallbackServer.start(state: state, port: 51121, path: "/oauth-callback")
        let code = try await authorizeInBrowser(
            URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            clientID: Self.clientID, scopes: Self.scopes, state: state, pkce: pkce, server: server,
            extraQuery: [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent")],
            prompt: prompt, pastedCode: pastedCode
        )
        let response = try await LoginHTTP.postForm(Self.tokenURL, fields: [
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!
        let userInfo = try await LoginHTTP.get(userInfoURL, bearerToken: token.accessToken, using: http)
        let user = try? LoginHTTP.decode(GoogleUserInfo.self, from: userInfo)
        return (user?.email ?? "Google Account", .oauth(OAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            extras: (user?.id ?? user?.email).map { [OAuthTokens.identityKey: $0] } ?? [:]
        )))
    }
}

private struct ClaudeProfileResponse: Decodable {
    struct Account: Decodable { let email: String?; let uuid: String? }
    struct Organization: Decodable { let uuid: String? }
    let account: Account?
    let organization: Organization?
    let email: String?
}

private struct GoogleUserInfo: Decodable { let id: String?; let email: String? }

private struct CodexDeviceStart: Decodable {
    let deviceAuthID: String
    let userCode: String
    let intervalValue: TimeInterval
    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case intervalValue = "interval"
    }
    var interval: TimeInterval { intervalValue }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try values.decode(String.self, forKey: .deviceAuthID)
        userCode = try values.decode(String.self, forKey: .userCode)
        if let interval = try? values.decode(TimeInterval.self, forKey: .intervalValue) {
            intervalValue = interval
        } else if let interval = try? values.decode(String.self, forKey: .intervalValue), let number = TimeInterval(interval) {
            intervalValue = number
        } else {
            intervalValue = 5
        }
    }
}

private struct CodexDeviceToken: Decodable {
    let authorizationCode: String
    let codeVerifier: String
    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
    }
}

private struct CodexAccessClaims: Decodable {
    struct Auth: Decodable {
        let chatgptAccountID: String?
        enum CodingKeys: String, CodingKey { case chatgptAccountID = "chatgpt_account_id" }
    }
    let auth: Auth?
    enum CodingKeys: String, CodingKey { case auth = "https://api.openai.com/auth" }
}

private struct CodexIDClaims: Decodable { let email: String? }
