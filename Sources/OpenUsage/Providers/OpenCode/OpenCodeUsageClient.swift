import Foundation

struct OpenCodeUsageClient: Sendable {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    var http: any HTTPClient

    func fetchUsage(apiKey: String) async throws -> HTTPResponse {
        try await LoginHTTP.get(Self.usageURL, bearerToken: apiKey, using: http, headers: ["Accept": "application/json"])
    }
}
