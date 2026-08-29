import Foundation

struct OrcaRouterUsageClient: Sendable {
    static let baseURL = "https://api.orcarouter.ai/v1"
    /// Total spend so far, OpenAI-shape `OpenAIUsageResponse` with a `total_usage` scalar.
    static let usageURL = "\(baseURL)/dashboard/billing/usage"
    /// Workspace balance, an OrcaRouter-specific object carrying the funded wallet and free credits.
    static let balanceURL = "\(baseURL)/balance"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Workspace-wide total spend so far. Summary endpoint — no per-day breakdown.
    func fetchUsage(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.usageURL, apiKey: apiKey)
    }

    /// Account balance: funded wallet plus free credits, in USD. The wallet is what prepaid
    /// platform traffic draws down; this is the closest analog to OpenRouter's `/credits`.
    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.balanceURL, apiKey: apiKey)
    }

    private func get(_ urlString: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw OrcaRouterUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
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

enum OrcaRouterUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach OrcaRouter. Check your connection."
        case .invalidResponse:
            return "OrcaRouter usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "OrcaRouter request failed (HTTP \(status))."
        }
    }
}
