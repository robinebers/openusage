import Foundation

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The user's active subscription(s) — best-effort, used only to surface the plan name. A failure
    /// here must not blank out the quota meters, so the provider treats it as optional.
    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    /// Session token usage and web-search quotas. Required for a usable snapshot.
    func fetchQuota(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum ZAIUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The key is valid but the account has no GLM Coding Plan (the quota endpoint answers a 2xx with
    /// `success:false`). Distinct from a malformed/failed request — there is simply nothing to meter.
    case noCodingPlan

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noCodingPlan:
            return "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."
        }
    }
}
