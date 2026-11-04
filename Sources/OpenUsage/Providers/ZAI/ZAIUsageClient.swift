import Foundation

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let resetListURL = URL(string: "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")!
    static let useResetURL = URL(string: "https://api.z.ai/api/biz/customer-package-reset/use")!

    var http: any HTTPClient

    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    func fetchQuota(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    func fetchResets(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.resetListURL, apiKey: apiKey)
    }

    func useReset(_ reset: ZAIReset, requestID: String, apiKey: String) async throws -> HTTPResponse {
        let payload: [String: Any] = [
            "targetType": "PERSONAL",
            "resetType": reset.window.rawValue,
            "recordId": reset.recordID,
            "requestId": requestID,
            "grantType": reset.grantType
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.useResetURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            timeout: 15
        ))
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
