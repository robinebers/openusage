import Foundation
import os
import XCTest
@testable import OpenUsage

final class ProviderLoginTests: XCTestCase {
    func testClaudeLoginExchangesCodeAndMapsProfile() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/v1/oauth/token":
                Self.response(#"{"access_token":"claude-access","refresh_token":"claude-refresh","expires_in":3600}"#)
            case "/api/oauth/profile":
                Self.response(#"{"account":{"email":"claude@example.com"}}"#)
            default:
                Self.response("{}", status: 404)
            }
        }
        let prompt = PromptCapture()
        let callback = CallbackStatus()

        let result = try await ClaudeLogin(http: http).login(
            prompt: Self.browserPrompt(prompt, callback: callback),
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "claude@example.com")
        XCTAssertEqual(callback.value, 200)
        let authorizeURL = try XCTUnwrap(prompt.value?.browserURL)
        let query = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "user:profile")
        let tokenRequest = try XCTUnwrap(http.requests.first { $0.url.path == "/v1/oauth/token" })
        let body = try XCTUnwrap(Self.jsonBody(tokenRequest))
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["code"] as? String, "fake-authorization-code")
        XCTAssertEqual(body["client_id"] as? String, ClaudeLogin.clientID)
        XCTAssertEqual((body["redirect_uri"] as? String).flatMap(URL.init(string:))?.host, "localhost")
        let verifier = try XCTUnwrap(body["code_verifier"] as? String)
        XCTAssertNotEqual(body["state"] as? String, verifier)
        XCTAssertEqual(body["state"] as? String, query.first { $0.name == "state" }?.value)
        XCTAssertFalse(authorizeURL.absoluteString.contains(verifier), "the authorize URL carries the challenge, never the verifier")
    }

    func testClaudeLoginFailsWhenItCannotReadTheProfile() async throws {
        let http = RoutingHTTPClient { request in
            request.url.path == "/v1/oauth/token"
                ? Self.response(#"{"access_token":"claude-access","refresh_token":"claude-refresh","expires_in":3600}"#)
                : Self.response(#"{"type":"error","error":{"type":"rate_limit_error"}}"#, status: 429)
        }
        do {
            let result = try await ClaudeLogin(http: http).login(
                prompt: Self.browserPrompt(PromptCapture(), callback: CallbackStatus()),
                pastedCode: emptyInput()
            )
            XCTFail("signed in as \(result.label) without the profile that identifies the account")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude didn’t return your profile. Click Try Again to sign in again.")
        }
    }

    func testCodexLoginUsesPiOriginatorAndMapsAccountClaims() async throws {
        let accessToken = Self.jwt(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"chatgpt-account"}}"#)
        let idToken = Self.jwt(#"{"email":"codex@example.com"}"#)
        let http = RoutingHTTPClient { request in
            guard request.url.path == "/oauth/token" else { return Self.response("{}", status: 404) }
            return Self.response("""
            {"access_token":"\(accessToken)","refresh_token":"codex-refresh","id_token":"\(idToken)","expires_in":3600}
            """)
        }
        let prompt = PromptCapture()
        let callback = CallbackStatus()

        let result = try await CodexLogin(http: http).login(
            prompt: Self.browserPrompt(prompt, callback: callback),
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "codex@example.com")
        XCTAssertEqual(callback.value, 200)
        guard case .oauth(let tokens) = result.credential else {
            return XCTFail("Expected OAuth credentials")
        }
        XCTAssertEqual(tokens.extras["chatgpt_account_id"], "chatgpt-account")
        let authorizeURL = try XCTUnwrap(prompt.value?.browserURL)
        let query = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "originator" }?.value, "pi")
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "openid profile email offline_access")
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, "http://localhost:1455/auth/callback")
        let body = Self.formBody(try XCTUnwrap(http.requests.first { $0.url.path == "/oauth/token" }))
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["client_id"], CodexLogin.clientID)
        XCTAssertEqual(body["code"], "fake-authorization-code")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertFalse(body["code_verifier", default: ""].isEmpty)
    }

    func testCopilotDeviceLoginMapsGitHubProfile() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/login/device/code":
                Self.response(#"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":600,"interval":1}"#)
            case "/login/oauth/access_token":
                Self.response(#"{"access_token":"copilot-access"}"#)
            case "/user":
                Self.response(#"{"login":"copilot-user"}"#)
            default:
                Self.response("{}", status: 404)
            }
        }
        let prompt = PromptCapture()

        let result = try await CopilotLogin(http: http).login(
            prompt: { prompt.store($0) },
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "copilot-user")
        XCTAssertEqual(prompt.value?.deviceCode?.userCode, "ABCD-EFGH")
        let start = try XCTUnwrap(http.requests.first { $0.url.path == "/login/device/code" })
        XCTAssertEqual(Self.formBody(start)["scope"], "read:user")
        let token = try XCTUnwrap(http.requests.first { $0.url.path == "/login/oauth/access_token" })
        XCTAssertEqual(Self.formBody(token)["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertEqual(Self.formBody(token)["device_code"], "device")
    }

    func testGrokDeviceLoginMapsEmailFromToken() async throws {
        let accessToken = Self.jwt(#"{"email":"grok@example.com"}"#)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/oauth2/device/code":
                Self.response(#"{"device_code":"device","user_code":"GROK-CODE","verification_uri":"https://auth.x.ai/activate","expires_in":600,"interval":1}"#)
            case "/oauth2/token":
                Self.response("""
                {"access_token":"\(accessToken)","refresh_token":"grok-refresh","expires_in":3600}
                """)
            default:
                Self.response("{}", status: 404)
            }
        }
        let prompt = PromptCapture()

        let result = try await GrokLogin(http: http).login(
            prompt: { prompt.store($0) },
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "grok@example.com")
        XCTAssertEqual(prompt.value?.deviceCode?.userCode, "GROK-CODE")
        let start = try XCTUnwrap(http.requests.first { $0.url.path == "/oauth2/device/code" })
        XCTAssertEqual(Self.formBody(start)["client_id"], GrokLogin.clientID)
        XCTAssertEqual(Self.formBody(start)["scope"], "openid profile email offline_access grok-cli:access api:access")
        let token = try XCTUnwrap(http.requests.first { $0.url.path == "/oauth2/token" })
        XCTAssertEqual(Self.formBody(token)["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertEqual(Self.formBody(token)["device_code"], "device")
    }

    func testCursorLoginPollsForTokens() async throws {
        let http = RoutingHTTPClient { _ in
            Self.response(#"{"accessToken":"\#(Self.jwt(#"{"sub":"auth0|user_abc"}"#))","refreshToken":"cursor-refresh","authId":"auth0|user_abc"}"#)
        }
        let prompt = PromptCapture()

        let result = try await CursorLogin(http: http).login(
            prompt: { prompt.store($0) },
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "Cursor Account")
        XCTAssertEqual(result.credential.identity, "cursor:user_abc", "the id comes from the token's subject; the poll carries no user id")
        let authorizeURL = try XCTUnwrap(prompt.value?.browserURL)
        XCTAssertEqual(authorizeURL.host, "cursor.com")
        XCTAssertEqual(authorizeURL.path, "/loginDeepControl")
        let authorizeQuery = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(authorizeQuery.first { $0.name == "mode" }?.value, "login")
        XCTAssertEqual(authorizeQuery.first { $0.name == "redirectTarget" }?.value, "cli")
        let poll = try XCTUnwrap(http.requests.first { $0.url.path == "/auth/poll" })
        let pollQuery = URLComponents(url: poll.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertFalse(pollQuery?.first { $0.name == "uuid" }?.value?.isEmpty ?? true)
        XCTAssertFalse(pollQuery?.first { $0.name == "verifier" }?.value?.isEmpty ?? true)
    }

    func testCursorLoginNamesTheAccountByTheProfileEmail() async throws {
        let accessToken = Self.jwt(#"{"sub":"auth0|user_abc"}"#)
        let http = RoutingHTTPClient { request in
            request.url.path == "/api/auth/me"
                ? Self.response(#"{"email":"dev@example.com","name":"Dev","sub":"auth0|user_abc"}"#)
                : Self.response(#"{"accessToken":"\#(accessToken)","refreshToken":"cursor-refresh"}"#)
        }

        let result = try await CursorLogin(http: http).login(prompt: { _ in }, pastedCode: emptyInput())

        XCTAssertEqual(result.label, "dev@example.com")
        let profile = try XCTUnwrap(http.requests.first { $0.url.path == "/api/auth/me" })
        XCTAssertEqual(profile.url.host, "cursor.com")
        XCTAssertEqual(profile.headers["Cookie"], "WorkosCursorSessionToken=user_abc%3A%3A\(accessToken)")
    }

    func testCursorLoginKeepsTheDefaultNameWhenTheProfileReadFails() async throws {
        let http = RoutingHTTPClient { request in
            request.url.path == "/api/auth/me"
                ? Self.response("{}", status: 500)
                : Self.response(#"{"accessToken":"\#(Self.jwt(#"{"sub":"auth0|user_abc"}"#))","refreshToken":"cursor-refresh"}"#)
        }

        let result = try await CursorLogin(http: http).login(prompt: { _ in }, pastedCode: emptyInput())

        XCTAssertNotNil(http.requests.first { $0.url.path == "/api/auth/me" })
        XCTAssertEqual(result.label, "Cursor Account")
        XCTAssertEqual(result.credential.identity, "cursor:user_abc")
    }

    func testOllamaKeyLoginNamesTheAccountByTheEmailOfItsPlanRead() async throws {
        for account in [#"{"Email":"dev@example.com","Name":"dev","Plan":"pro"}"#, #"{"email":"dev@example.com","name":"dev","plan":"pro"}"#] {
            let http = Self.ollamaHTTP(account: account)

            let result = try await APIKeyLogin(kind: .ollama, http: http).login(prompt: { _ in }, pastedCode: pastedInput("ollama-key"))

            XCTAssertEqual(result.label, "dev@example.com")
            XCTAssertEqual(http.requests.filter { $0.url.path == "/api/me" }.count, 1, "the plan read names the account; no second request")
        }
    }

    func testOllamaKeyLoginKeepsTheProviderNameWithoutAnEmail() async throws {
        for (account, status) in [(#"{"Name":"dev","Plan":"free"}"#, 200), (#"{"Email":""}"#, 200), ("{}", 401)] {
            let http = Self.ollamaHTTP(account: account, status: status)

            let result = try await APIKeyLogin(kind: .ollama, http: http).login(prompt: { _ in }, pastedCode: pastedInput("ollama-key"))

            XCTAssertEqual(result.label, "Ollama")
        }
    }

    func testAntigravityLoginExchangesCodeAndMapsGoogleProfile() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/token":
                Self.response(#"{"access_token":"google-access","refresh_token":"google-refresh","expires_in":3600}"#)
            case "/oauth2/v1/userinfo":
                Self.response(#"{"email":"google@example.com"}"#)
            default:
                Self.response("{}", status: 404)
            }
        }
        let prompt = PromptCapture()
        let callback = CallbackStatus()

        let result = try await AntigravityLogin(http: http).login(
            prompt: Self.browserPrompt(prompt, callback: callback),
            pastedCode: emptyInput()
        )

        XCTAssertEqual(result.label, "google@example.com")
        XCTAssertEqual(callback.value, 200)
        let authorizeURL = try XCTUnwrap(prompt.value?.browserURL)
        let query = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            query.first { $0.name == "scope" }?.value,
            "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"
        )
        let body = Self.formBody(try XCTUnwrap(http.requests.first { $0.url.path == "/token" }))
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["client_id"], AntigravityLogin.clientID)
        XCTAssertEqual(body["code"], "fake-authorization-code")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:51121/oauth-callback")
        XCTAssertFalse(body["code_verifier", default: ""].isEmpty)
        let verifier = try XCTUnwrap(body["code_verifier"])
        XCTAssertNotEqual(query.first { $0.name == "state" }?.value, verifier)
        XCTAssertFalse(authorizeURL.absoluteString.contains(verifier), "the authorize URL carries the challenge, never the verifier")
    }

    private func emptyInput() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    private func pastedInput(_ value: String) -> AsyncStream<String> {
        AsyncStream { $0.yield(value); $0.finish() }
    }

    private static func ollamaHTTP(account: String, status: Int = 200) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            request.url.path == "/api/me"
                ? Self.response(account, status: status)
                : Self.response(#"{"included":{"balance_usd":72.5,"allowance_usd":100}}"#)
        }
    }

    private static func browserPrompt(
        _ prompt: PromptCapture,
        callback: CallbackStatus
    ) -> @Sendable (LoginPrompt) async -> Void {
        { value in
            prompt.store(value)
            guard case .browser(let authorizeURL, _) = value else { return }
            callback.store(await Self.completeLoopbackCallback(authorizeURL))
        }
    }

    private static func completeLoopbackCallback(_ authorizeURL: URL) async -> Int? {
        guard
            let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems,
            let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
            let state = items.first(where: { $0.name == "state" })?.value,
            var callback = URLComponents(string: redirect)
        else { return nil }
        callback.host = "127.0.0.1"
        callback.queryItems = [
            URLQueryItem(name: "code", value: "fake-authorization-code"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = callback.url else { return nil }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private static func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
    }

    private static func jsonBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func formBody(_ request: HTTPRequest) -> [String: String] {
        guard
            let body = request.body.flatMap({ String(data: $0, encoding: .utf8) }),
            let items = URLComponents(string: "https://example.invalid/?\(body)")?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
    }

    private static func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).signature"
    }
}

private final class PromptCapture: @unchecked Sendable {
    private let prompt = OSAllocatedUnfairLock<LoginPrompt?>(initialState: nil)

    var value: LoginPrompt? { prompt.withLock { $0 } }

    func store(_ value: LoginPrompt) {
        prompt.withLock { $0 = value }
    }
}

private extension LoginPrompt {
    var browserURL: URL? {
        guard case .browser(let url, _) = self else { return nil }
        return url
    }

    var deviceCode: (userCode: String, verificationURL: URL)? {
        guard case .deviceCode(let userCode, let verificationURL) = self else { return nil }
        return (userCode, verificationURL)
    }
}

private final class CallbackStatus: @unchecked Sendable {
    private let status = OSAllocatedUnfairLock<Int?>(initialState: nil)

    var value: Int? { status.withLock { $0 } }

    func store(_ value: Int?) {
        status.withLock { $0 = value }
    }
}
