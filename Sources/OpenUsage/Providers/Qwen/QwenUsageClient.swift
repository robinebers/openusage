import Foundation

/// Calls the home.qwencloud.com console API — the same internal endpoints the token-plan billing
/// page uses. API keys cannot reach this data (they are inference-only), so every call carries the
/// user's captured browser session cookies, and mutating calls additionally carry the `sec_token`
/// CSRF value fetched from `info.json`.
struct QwenUsageClient: Sendable {
    static let infoURL = URL(string: "https://home.qwencloud.com/tool/user/info.json")!
    static let apiURL = URL(string: "https://cs-data.qwencloud.com/data/api.json")!
    static let homeOrigin = "https://home.qwencloud.com"
    static let billingReferer = "https://home.qwencloud.com/billing/subscription/token-plan-individual"
    /// The console is bot-watched; a plain HTTP client UA trips its defenses, so the calls present
    /// the same browser identity the captured request used.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    /// The three personal token-plan endpoints behind the gateway. Raw values are the URL path
    /// segments; `apiName` is the gateway's `zeldaHttp.apikeyMgr.`-prefixed route.
    enum Endpoint: String, CaseIterable, Sendable {
        case usage
        case subscription
        case quotaConfig = "quota-config"

        var apiName: String { "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/\(rawValue)" }
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Session liveness probe and `sec_token` source: `data.secToken` from the user-info endpoint.
    /// A dead session answers without a token (the provider reads that as `.sessionExpired`).
    func fetchInfo(cookies: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.infoURL,
            headers: [
                "Cookie": cookies,
                "Accept": "application/json, text/plain, */*",
                "Referer": Self.billingReferer,
                "User-Agent": Self.userAgent
            ],
            timeout: 15
        ))
    }

    /// One gateway call (`/data/api.json`) for a token-plan endpoint. The endpoint rides in BOTH
    /// the query string and the form body's `params` envelope — the captured browser request
    /// carries it twice, so so do we.
    func fetch(_ endpoint: Endpoint, cookies: String, secToken: String, region: String) async throws -> HTTPResponse {
        // Query built by hand (not URLComponents) so the `api` value percent-encodes exactly like
        // the captured browser request — slashes as %2F. URLComponents would leave them literal.
        let url = URL(string: "\(Self.apiURL.absoluteString)?product=sfm_bailian&action=IntlBroadScopeAspnGateway&api=\(endpoint.apiName.urlFormEncoded)")!
        let body = Self.formBody(endpoint: endpoint, secToken: secToken, region: region)
        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Cookie": cookies,
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json, text/plain, */*",
                "Origin": Self.homeOrigin,
                "Referer": Self.billingReferer,
                "User-Agent": Self.userAgent
            ],
            body: Data(body.utf8),
            timeout: 15
        ))
    }

    /// The `application/x-www-form-urlencoded` body: gateway fields plus the JSON `params` envelope.
    static func formBody(endpoint: Endpoint, secToken: String, region: String) -> String {
        [
            "product=sfm_bailian",
            "action=IntlBroadScopeAspnGateway",
            "sec_token=\(secToken.urlFormEncoded)",
            "region=\(region.urlFormEncoded)",
            "params=\(paramsEnvelope(apiName: endpoint.apiName).urlFormEncoded)"
        ].joined(separator: "&")
    }

    /// The JSON envelope the gateway requires around every call. `cornerstoneParam` is the console's
    /// static site-identity block — identical for every personal token-plan endpoint (verified
    /// against a captured browser request). Built as a literal (not JSONSerialization, which would
    /// escape the slashes in `apiName` as `\/` and diverge from the captured payload byte-for-byte).
    static func paramsEnvelope(apiName: String) -> String {
        """
        {"Api":"\(apiName)","Data":{"cornerstoneParam":{"console":"ONE_CONSOLE",\
        "consoleSite":"QWENCLOUD","domain":"home.qwencloud.com","productCode":"p_efm",\
        "protocol":"V2","xsp_lang":"en-US"}},"V":"1.0"}
        """
    }
}

enum QwenUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The session cookies no longer authenticate (the gateway reports `ConsoleNeedLogin`, or
    /// `info.json` stopped returning a `secToken`). The fix is always a fresh sign-in — cookies have
    /// no programmatic refresh path.
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .sessionExpired:
            return "Qwen Cloud session expired. Open Qwen in Customize to sign in again."
        }
    }
}
