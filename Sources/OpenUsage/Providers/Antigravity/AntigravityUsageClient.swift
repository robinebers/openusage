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

/// Result of a Google OAuth token refresh, split so a dead refresh token reads as expired auth while a
/// 5xx/network failure reads as a transient outage.
enum TokenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, expiresIn: Double)
    case authFailed
    case unavailable
}

/// All network I/O for Antigravity: the local language-server RPC (loopback HTTPS, self-signed), the
/// Google Cloud Code endpoints, and the Google OAuth token refresh.
struct AntigravityUsageClient: Sendable {
    static let lsService = "exa.language_server_pb.LanguageServerService"
    // The daily endpoint can omit Gemini quotas from a successful response; prefer production.
    static let cloudCodeURLs = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com"
    ]
    static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    static let googleOAuthURL = "https://oauth2.googleapis.com/token"
    // Google OAuth "installed application" client credentials, extracted verbatim from the Antigravity
    // app bundle — the same pair the shipped app and the legacy Tauri plugin use. For installed-app OAuth
    // clients Google does not treat the "secret" as confidential (it ships in every copy of the client),
    // so committing it here is an intentional, accepted trade-off, not a leaked private key. It's required
    // for the refresh-token grant — without it we can't refresh the keychain token when the app is closed.
    static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let googleClientSecret = "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"
    static let lsMetadata = ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]

    /// Loopback session that trusts the LS's self-signed cert; remote calls use full validation.
    var lsHTTP: HTTPClient
    var http: HTTPClient

    init(
        lsHTTP: HTTPClient = URLSessionHTTPClient(allowsInsecureLoopback: true),
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.lsHTTP = lsHTTP
        self.http = http
    }

    /// Call a language-server RPC method. Returns nil on a transport failure (port not the live one).
    func callLS(scheme: String, port: Int, csrf: String, method: String) async -> HTTPResponse? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.lsService)/\(method)") else { return nil }
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": Self.lsMetadata])
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "x-codeium-csrf-token": csrf
            ],
            body: body,
            timeout: 10
        )
        return try? await lsHTTP.send(request)
    }

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

    /// Exchange a Google refresh token for a fresh access token. Distinguishes a dead refresh token
    /// (4xx, e.g. `invalid_grant`) from a transient failure (5xx / network / undecodable) so the caller
    /// can report "sign-in expired" vs "temporarily unavailable" correctly.
    func refreshGoogleToken(_ refreshToken: String) async -> TokenRefreshOutcome {
        guard let url = URL(string: Self.googleOAuthURL) else { return .unavailable }
        let form = [
            "client_id=\(Self.googleClientID.urlFormEncoded)",
            "client_secret=\(Self.googleClientSecret.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        )
        guard let response = try? await http.send(request) else { return .unavailable }
        switch response.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: response.body),
                  let access = decoded.accessToken?.nilIfEmpty
            else {
                return .unavailable // 2xx but undecodable / empty — treat as transient
            }
            return .refreshed(accessToken: access, expiresIn: decoded.expiresIn ?? 3600)
        case 408, 429:
            return .unavailable // request timeout / rate limited — transient, not a revoked token
        case 400..<500:
            return .authFailed // invalid_grant / invalid_client — refresh token revoked or expired
        default:
            return .unavailable // 5xx and anything else — transient
        }
    }
}

struct GoogleTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
