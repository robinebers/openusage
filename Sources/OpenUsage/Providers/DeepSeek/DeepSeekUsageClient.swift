import Foundation

struct DeepSeekUsageClient: Sendable {
    static let balanceURL = "https://api.deepseek.com/user/balance"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.balanceURL) else {
            throw DeepSeekUsageError.invalidResponse
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

enum DeepSeekUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach DeepSeek. Check your connection."
        case .invalidResponse:
            return "DeepSeek usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "DeepSeek request failed (HTTP \(status))."
        }
    }
}
