import Foundation

struct DeepSeekUsageClient: Sendable {
    static let balanceURL = "https://api.deepseek.com/user/balance"
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.balanceURL) else { throw DeepSeekUsageError.invalidResponse }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
            timeout: 15
        ))
    }
}

enum DeepSeekUsageError: Error, LocalizedError, CategorizedError, Equatable {
    case connectionFailed, invalidResponse, unsupportedCurrency
    case requestFailed(Int)

    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .unsupportedCurrency: .notAvailable
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .connectionFailed: "Couldn't reach DeepSeek. Check your connection."
        case .invalidResponse: "DeepSeek balance data unavailable. Try again later."
        case .unsupportedCurrency: "DeepSeek returned no USD or CNY balance."
        case .requestFailed(let status): "DeepSeek request failed (HTTP \(status))."
        }
    }
}
