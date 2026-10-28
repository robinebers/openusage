import Foundation

enum LoginHTTP {
    static func postForm(
        _ url: URL,
        fields: [String: String],
        using client: any HTTPClient,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var requestHeaders = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json"
        ]
        requestHeaders.merge(headers) { _, new in new }
        let body = fields
            .map { "\($0.key)=\($0.value.urlFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        return try await client.send(HTTPRequest(method: "POST", url: url, headers: requestHeaders, body: body))
    }

    static func postJSON(
        _ url: URL,
        fields: [String: String],
        using client: any HTTPClient
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: fields)
        )
        return try await client.send(request)
    }

    static func get(
        _ url: URL,
        bearerToken: String? = nil,
        using client: any HTTPClient,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var requestHeaders = headers
        if let bearerToken { requestHeaders["Authorization"] = "Bearer \(bearerToken)" }
        return try await client.send(HTTPRequest(method: "GET", url: url, headers: requestHeaders))
    }

    static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            throw LoginError.requestFailed(response.statusCode)
        }
        return try JSONDecoder().decode(type, from: response.body)
    }

    static func jsonObject(_ response: HTTPResponse) -> [String: String] {
        guard let values = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { return [:] }
        return values.compactMapValues { $0 as? String }
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let idToken: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
    var expiry: Date? { expiresIn.map { Date().addingTimeInterval($0) } }

    func grant(now: Date) -> OAuthGrant {
        OAuthGrant(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }
}

/// What a token endpoint answers to a refresh grant. A `nil` refresh token keeps the stored one.
struct OAuthGrant: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

extension String {
    func jwtPayload<T: Decodable>(as type: T.Type) -> T? {
        guard let data = ProviderParse.jwtPayloadData(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum LoginError: LocalizedError, Sendable {
    case cancelled
    case invalidResponse
    case requestFailed(Int)
    case invalidState
    case invalidCode
    case listenerFailed(String)
    case invalidCallback
    case authorizationFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .invalidResponse: "The sign-in service returned an invalid response."
        case .requestFailed(let status): "Sign-in failed with HTTP \(status)."
        case .invalidState: "The sign-in response did not match this request."
        case .invalidCode: "The authorization code was invalid."
        case .listenerFailed(let detail): "Could not start the sign-in callback: \(detail)"
        case .invalidCallback: "The sign-in callback request was invalid."
        case .authorizationFailed(let error): "Authorization failed: \(error)"
        case .failed(let message): message
        }
    }
}

enum AuthorizationInput: Sendable {
    case callback(String)
    case pasted(String)
}

func waitForAuthorizationInput(
    server: LoopbackCallbackServer,
    pastedCode: AsyncStream<String>
) async throws -> AuthorizationInput {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: AuthorizationInput.self) { tasks in
            tasks.addTask { .callback(try await server.waitForCode()) }
            tasks.addTask {
                var iterator = pastedCode.makeAsyncIterator()
                guard let value = await iterator.next() else { throw LoginError.cancelled }
                return .pasted(value)
            }
            guard let result = try await tasks.next() else { throw LoginError.cancelled }
            server.cancel()
            tasks.cancelAll()
            return result
        }
    } onCancel: {
        server.cancel()
    }
}

func authorizeInBrowser(
    _ authorizeURL: URL,
    clientID: String,
    scopes: String,
    state: String,
    pkce: PKCEPair,
    server: LoopbackCallbackServer,
    extraQuery: [URLQueryItem] = [],
    prompt: @Sendable (LoginPrompt) async -> Void,
    pastedCode: AsyncStream<String>
) async throws -> String {
    defer { server.cancel() }
    var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: server.redirectURI),
        URLQueryItem(name: "scope", value: scopes),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state)
    ] + extraQuery
    guard let url = components.url else { throw LoginError.invalidResponse }
    await prompt(.browser(url, acceptsPastedCode: true))
    let input = try await waitForAuthorizationInput(server: server, pastedCode: pastedCode)
    return try authorizationCode(from: input, expectedState: state)
}

func authorizationCode(from input: AuthorizationInput, expectedState: String) throws -> String {
    switch input {
    case .callback(let code):
        return code
    case .pasted(let value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: (code: String?, state: String?)
        // Only a whole callback URL is read for its query: `URL(string:)` also accepts a bare code or
        // a `code#state` pair as a relative URL, which has no query at all.
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parsed = (
                components.queryItems?.first(where: { $0.name == "code" })?.value,
                components.queryItems?.first(where: { $0.name == "state" })?.value
            )
        } else if trimmed.contains("#") {
            let values = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
            parsed = (values.first, values.count > 1 ? values[1] : nil)
        } else {
            parsed = (trimmed, nil)
        }
        guard let code = parsed.code, !code.isEmpty else { throw LoginError.invalidCode }
        guard parsed.state == expectedState else { throw LoginError.invalidState }
        return code
    }
}
