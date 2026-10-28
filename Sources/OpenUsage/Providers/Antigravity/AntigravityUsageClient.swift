import Foundation

/// Outcome of a Cloud Code call, split so the orchestrator can tell a genuine auth failure (refresh)
/// apart from a transient outage (try the next base URL / strategy, don't refresh).
enum CloudCodeOutcome: Sendable {
    case ok(Data)
    case authFailed
    case unavailable
}

/// Outcome of a Cloud Code call made on every base URL: the 2xx bodies in base-URL order.
enum CloudCodeAllHostsOutcome: Sendable {
    case ok([Data])
    case authFailed
    case unavailable
}

extension AntigravityLogin {
    /// Exchange a Google refresh token for a fresh access token. A dead refresh token (4xx, e.g.
    /// `invalid_grant`) reads as an expired sign-in; a transient failure (5xx / network / undecodable)
    /// as "temporarily unavailable".
    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let unavailable = ProviderError.unavailable(AntigravityUsageClient.unavailableMessage)
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
        guard let response = try? await http.send(request) else { throw unavailable }
        switch response.statusCode {
        case 200..<300:
            guard let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: response.body),
                  !token.accessToken.isEmpty
            else {
                throw unavailable // 2xx but undecodable / empty — treat as transient
            }
            return OAuthGrant(accessToken: token.accessToken, expiresAt: now.addingTimeInterval(token.expiresIn ?? 3600))
        case 408, 429:
            throw unavailable // request timeout / rate limited — transient, not a revoked token
        case 400..<500:
            throw ProviderError.signInExpired(.antigravity) // invalid_grant / invalid_client — refresh token revoked or expired
        default:
            throw unavailable // 5xx and anything else — transient
        }
    }
}

/// Antigravity's usage I/O: the Google Cloud Code endpoints.
struct AntigravityUsageClient: Sendable {
    /// The card's message for an `.unavailable` outcome: every host was down or the refresh failed transiently.
    static let unavailableMessage = "Antigravity usage is temporarily unavailable. Try again shortly."
    // The daily endpoint can omit Gemini quotas from a successful response; prefer production.
    static let cloudCodeURLs = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com"
    ]
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"

    var http: HTTPClient

    /// POST a Cloud Code endpoint, trying each base URL in turn. A 401/403 short-circuits to `.authFailed`
    /// (same token would fail on the other base); other non-2xx / transport errors fall through to the
    /// next base and finally `.unavailable`.
    func cloudCode(path: String, token: String, userAgent: String, body: [String: String]) async -> CloudCodeOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return await cloudCode(path: path, token: token, userAgent: userAgent, payload: payload)
    }

    /// `loadCodeAssist` with Antigravity's client metadata. Without it the response carries only
    /// `allowedTiers` — no `currentTier`/`paidTier` — so the plan can't be read.
    func loadCodeAssist(token: String) async -> CloudCodeOutcome {
        await cloudCode(path: Self.loadCodeAssistPath, token: token, userAgent: Self.clientUserAgent, payload: Self.loadCodeAssistPayload)
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

    /// `ClientMetadata` enum names as they appear in the Antigravity language server's protos.
    static let loadCodeAssistPayload = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )

    private func cloudCode(path: String, token: String, userAgent: String, payload: Data) async -> CloudCodeOutcome {
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + path) else { continue }
            let request = Self.cloudCodeRequest(url: url, token: token, userAgent: userAgent, payload: payload)
            guard let response = try? await http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
        }
        return .unavailable
    }

    /// POST a Cloud Code endpoint on each base URL in order and return every 2xx body in base-URL order.
    /// The hosts can disagree: `daily-cloudcode-pa` has answered the quota summary with only the Claude
    /// group while `cloudcode-pa` also returned Gemini, so a caller merging by id may need both. Stops
    /// after the first base when its 2xx body is one `isComplete` accepts: callers merge first-wins, so
    /// a later answer couldn't change the result. Any 2xx wins; otherwise a 401/403 on any base is
    /// `.authFailed`, and anything else `.unavailable`.
    func cloudCodeAllHosts(
        path: String,
        token: String,
        userAgent: String,
        body: [String: String],
        isComplete: (Data) -> Bool = { _ in false }
    ) async -> CloudCodeAllHostsOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var responses: [HTTPResponse] = []
        for (index, base) in Self.cloudCodeURLs.enumerated() {
            guard let url = URL(string: base + path) else { continue }
            let request = Self.cloudCodeRequest(url: url, token: token, userAgent: userAgent, payload: payload)
            guard let response = try? await http.send(request) else { continue }
            responses.append(response)
            if index == 0, (200..<300).contains(response.statusCode), isComplete(response.body) { break }
        }
        let bodies = responses.filter { (200..<300).contains($0.statusCode) }.map(\.body)
        if !bodies.isEmpty { return .ok(bodies) }
        if responses.contains(where: { $0.statusCode == 401 || $0.statusCode == 403 }) { return .authFailed }
        return .unavailable
    }

    private static func cloudCodeRequest(url: URL, token: String, userAgent: String, payload: Data) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "User-Agent": userAgent
            ],
            body: payload,
            timeout: 15
        )
    }
}
