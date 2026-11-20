import Foundation

struct DeepSeekUsageClient: Sendable {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    var http: any HTTPClient

    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        try await LoginHTTP.get(Self.balanceURL, bearerToken: apiKey, using: http, headers: ["Accept": "application/json"])
    }
}
