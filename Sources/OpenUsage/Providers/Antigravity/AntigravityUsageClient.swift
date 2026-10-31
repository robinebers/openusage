import Foundation

extension AntigravityLogin {
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let form = [
            "client_id=\(clientID.urlFormEncoded)",
            "client_secret=\(clientSecret.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        let request = HTTPRequest(
            method: "POST",
            url: tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        )
        let token = try await OAuthTokenResponse(renewal: http.send(request), kind: .antigravity)
        return OAuthGrant(accessToken: token.accessToken, expiresAt: now.addingTimeInterval(token.expiresIn ?? 3600))
    }
}

struct AntigravityUsageClient: Sendable {
    static let unavailableMessage = "Antigravity usage is temporarily unavailable. Try again shortly."
    // The daily endpoint can omit Gemini quotas from a successful response; prefer production.
    static let cloudCodeURLs = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com"
    ]
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"

    var http: HTTPClient

    /// The quota read answered 401: the access token was refused, so a renewed sign-in may read it.
    struct TokenRefused: Error {}

    /// `loadCodeAssist` with Antigravity's client metadata. Without it the response carries only
    /// `allowedTiers` — no `currentTier`/`paidTier` — so the plan can't be read. Each base URL is tried in
    /// turn: a 401/403 is an expired sign-in (the same token would fail on the other base); other non-2xx
    /// and transport errors fall through to the next base and finally "unavailable".
    func loadCodeAssist(token: String) async throws -> Data {
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + Self.loadCodeAssistPath) else { continue }
            let request = Self.cloudCodeRequest(url: url, token: token, payload: Self.loadCodeAssistPayload)
            guard let response = try? await http.send(request) else { continue }
            if ProviderError.isAuthFailure(response) { throw ProviderError.signInExpired(.antigravity) }
            if (200..<300).contains(response.statusCode) { return response.body }
        }
        throw ProviderError.unavailable(Self.unavailableMessage)
    }

    /// The Antigravity client's own User-Agent shape (`%s/%s (aidev_client; os_type=…; arch=…)` in its
    /// language server). Google marks other callers `UNSUPPORTED_CLIENT` and drops `paidTier`.
    static let clientUserAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=\(arch))"
    }()

    static let loadCodeAssistPayload = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )

    func quotaSummary(token: String, project: String?) async throws -> [Data] {
        let body = project.map { ["project": $0] } ?? [:]
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var responses: [HTTPResponse] = []
        var transportError: Error?
        for (index, base) in Self.cloudCodeURLs.enumerated() {
            guard let url = URL(string: base + Self.quotaSummaryPath) else { continue }
            let request = Self.cloudCodeRequest(url: url, token: token, payload: payload)
            let response: HTTPResponse
            do { response = try await http.send(request) } catch { transportError = error; continue }
            responses.append(response)
            if index == 0, (200..<300).contains(response.statusCode), AntigravityUsageMapper.isCompleteSummary(response.body) { break }
        }
        if responses.isEmpty, let transportError { throw transportError }
        let bodies = responses.filter { (200..<300).contains($0.statusCode) }.map(\.body)
        if !bodies.isEmpty { return bodies }
        if responses.contains(where: { $0.statusCode == 401 }) { throw TokenRefused() }
        if responses.contains(where: ProviderError.isAuthFailure) { throw ProviderError.signInExpired(.antigravity) }
        throw ProviderError.unavailable(Self.unavailableMessage)
    }

    private static func cloudCodeRequest(url: URL, token: String, payload: Data) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "User-Agent": clientUserAgent
            ],
            body: payload,
            timeout: 15
        )
    }
}
