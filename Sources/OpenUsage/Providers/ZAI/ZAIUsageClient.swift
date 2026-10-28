import Foundation

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

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
