import Foundation

/// Outcome of a Cloud Code call, split so the orchestrator can tell a genuine auth failure (refresh)
/// apart from a transient outage (try the next base URL / strategy, don't refresh).
enum CloudCodeOutcome: Sendable {
    case ok(Data)
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
    static let cloudCodeURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
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
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + path) else { continue }
            let request = HTTPRequest(
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
            guard let response = try? await http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
        }
        return .unavailable
    }

    /// Exchange a Google refresh token for a fresh access token. Distinguishes a dead refresh token
    /// (4xx, e.g. `invalid_grant`) from a transient failure (5xx / network / undecodable) so the caller
    /// can report "sign-in expired" vs "temporarily unavailable" correctly.
    func refreshGoogleToken(_ refreshToken: String) async -> TokenRefreshOutcome {
        guard let url = URL(string: Self.googleOAuthURL) else { return .unavailable }
        let form = [
            "client_id=\(Self.formEncoded(Self.googleClientID))",
            "client_secret=\(Self.formEncoded(Self.googleClientSecret))",
            "refresh_token=\(Self.formEncoded(refreshToken))",
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

    private static func formEncoded(_ value: String) -> String {
        // Conservative: refresh tokens contain `/`, so encode everything but alphanumerics.
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
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
