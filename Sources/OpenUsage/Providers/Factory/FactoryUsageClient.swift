import Foundation

enum FactoryRefreshOutcome: Sendable {
    case refreshed(accessToken: String, refreshToken: String?)
    case authFailed
    case unavailable
}

struct FactoryUsageClient: Sendable {
    static let appURL = "https://app.factory.ai"
    static let usageURL = "https://api.factory.ai/api/organization/subscription/usage"
    static let billingLimitsURL = "https://api.factory.ai/api/billing/limits"
    static let computeUsageURL = "https://api.factory.ai/api/organization/compute-usage"
    static let workOSAuthURL = "https://api.workos.com/user_management/authenticate"
    // Public WorkOS client id shipped in the Droid CLI — required for refresh-token grants.
    static let workOSClientID = "client_01HNM792M5G5G1A2THWPXKFMXB"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchSubscriptionUsage(accessToken: String, userID: String?) async throws -> HTTPResponse {
        var body: [String: Any] = ["useCache": true]
        if let userID { body["userId"] = userID }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var response = try await send(
            method: "POST",
            url: Self.usageURL,
            accessToken: accessToken,
            body: payload
        )
        if response.statusCode == 405 {
            AppLog.info(LogTag.http("factory"), "POST returned 405, retrying with GET")
            response = try await send(
                method: "GET",
                url: usageGETURL(body: body),
                accessToken: accessToken,
                body: nil
            )
        }
        return response
    }

    func fetchBillingLimits(accessToken: String) async throws -> HTTPResponse {
        try await send(method: "GET", url: Self.billingLimitsURL, accessToken: accessToken, body: nil)
    }

    func fetchComputeUsage(accessToken: String) async throws -> HTTPResponse {
        try await send(method: "GET", url: Self.computeUsageURL, accessToken: accessToken, body: nil)
    }

    func refreshToken(_ refreshToken: String) async -> FactoryRefreshOutcome {
        guard let url = URL(string: Self.workOSAuthURL) else { return .unavailable }
        let form = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "client_id=\(Self.workOSClientID.urlFormEncoded)"
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
            guard let body = ProviderParse.jsonObject(response.body),
                  let access = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else {
                return .unavailable
            }
            let refresh = (body["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return .refreshed(accessToken: access, refreshToken: refresh)
        case 400, 401:
            return .authFailed
        default:
            return .unavailable
        }
    }

    private func usageGETURL(body: [String: Any]) -> String {
        var params = ["useCache=\(body["useCache"] ?? true)"]
        if let userID = body["userId"] as? String, !userID.isEmpty {
            params.append("userId=\(userID.urlFormEncoded)")
        }
        return Self.usageURL + "?" + params.joined(separator: "&")
    }

    private func send(method: String, url: String, accessToken: String, body: Data?) async throws -> HTTPResponse {
        guard let requestURL = URL(string: url) else {
            throw FactoryUsageError.invalidResponse
        }
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage",
            "Origin": Self.appURL,
            "Referer": Self.appURL + "/",
            "x-factory-client": "web-app"
        ]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        return try await http.send(HTTPRequest(
            method: method,
            url: requestURL,
            headers: headers,
            body: body,
            timeout: 15
        ))
    }
}

enum FactoryUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Usage request failed. Check your connection."
        case .invalidResponse, .usageUnavailable:
            return "Usage response invalid. Try again later."
        case .requestFailed(let status):
            return "Usage request failed (HTTP \(status)). Try again later."
        }
    }
}
